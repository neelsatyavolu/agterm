#!/usr/bin/env node
/**
 * Makes sure agterm Remote's App ID and App Store provisioning profile exist and are current,
 * then writes the profile to the path given as the first argument and prints its UUID.
 *
 * Uses the team's App Store Connect API key from 1Password (no account holder needed), as
 * agmux's iPhone app does.
 *
 *   OP_ACCOUNT=<account> node scripts/asc-profile.mjs <out.mobileprovision>
 *
 * 1Password items (override with env):
 *   AGTERM_APPLE_KEY_ITEM   "Xanom Apple Dev Creds"           Key ID, issuer id, AuthKey_<KeyID>.p8
 *   AGTERM_IOS_CERT_ITEM    "Apple Distribution Certificate"  Serial Number
 *   AGTERM_APPLE_VAULT      "Private"
 */
import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';
import { writeFileSync } from 'node:fs';

export const BUNDLE_ID = 'co.xanom.agterm.remote';
export const APP_NAME = 'agterm Remote';
export const PROFILE_NAME = 'agterm Remote App Store';
/** App ID capabilities the app's entitlements need; a profile only carries those on when it was made. */
export const CAPABILITIES = ['PUSH_NOTIFICATIONS'];

const API = 'https://api.appstoreconnect.apple.com';
const VAULT = process.env.AGTERM_APPLE_VAULT || 'Private';
const KEY_ITEM = process.env.AGTERM_APPLE_KEY_ITEM || 'Xanom Apple Dev Creds';
const CERT_ITEM = process.env.AGTERM_IOS_CERT_ITEM || 'Apple Distribution Certificate';

const op = (...args) => execFileSync('op', args, { encoding: 'utf8' }).trim();
const field = (item, label) => op('item', 'get', item, '--vault', VAULT, '--fields', `label=${label}`, '--reveal');

/** App Store Connect JWT (ES256, 10 minutes). */
export function apiToken({ keyId, issuerId, privateKey }, now = Math.floor(Date.now() / 1000)) {
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const data = `${b64({ alg: 'ES256', kid: keyId, typ: 'JWT' })}.${b64({ iss: issuerId, iat: now, exp: now + 600, aud: 'appstoreconnect-v1' })}`;
  const sig = crypto.sign('sha256', Buffer.from(data), { key: privateKey, dsaEncoding: 'ieee-p1363' });
  return `${data}.${sig.toString('base64url')}`;
}

/** Picks the newest active App Store profile that includes the given certificate. */
export function pickProfile(profiles, certificateId) {
  return profiles
    .filter((p) => p.attributes.name === PROFILE_NAME && p.attributes.profileState === 'ACTIVE')
    .filter((p) => p.certificateIds.includes(certificateId))
    .sort((a, b) => b.attributes.expirationDate.localeCompare(a.attributes.expirationDate))[0];
}

async function main(out) {
  if (!out) throw new Error('usage: node scripts/asc-profile.mjs <out.mobileprovision>');
  const keyId = field(KEY_ITEM, 'Key ID');
  const key = {
    keyId,
    issuerId: field(KEY_ITEM, 'issuer id'),
    privateKey: op('read', `op://${VAULT}/${KEY_ITEM}/AuthKey_${keyId}.p8`),
  };
  const serial = field(CERT_ITEM, 'Serial Number');

  async function api(method, path, body) {
    const res = await fetch(`${API}${path}`, {
      method,
      headers: { Authorization: `Bearer ${apiToken(key)}`, 'Content-Type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined,
    });
    const json = await res.json().catch(() => ({}));
    if (!res.ok) {
      const detail = (json.errors || []).map((e) => `${e.code}: ${e.detail || e.title}`).join('; ');
      throw new Error(`${method} ${path} failed (HTTP ${res.status}) ${detail}`);
    }
    return json;
  }

  let bundle = (await api('GET', `/v1/bundleIds?filter[identifier]=${BUNDLE_ID}`)).data
    .find((b) => b.attributes.identifier === BUNDLE_ID);
  if (!bundle) {
    bundle = (await api('POST', '/v1/bundleIds', {
      data: { type: 'bundleIds', attributes: { identifier: BUNDLE_ID, name: APP_NAME, platform: 'IOS' } },
    })).data;
    console.error(`Registered App ID ${BUNDLE_ID}`);
  }

  const enabled = new Set((await api('GET', `/v1/bundleIds/${bundle.id}/bundleIdCapabilities`)).data
    .map((c) => c.attributes.capabilityType));
  let capabilitiesChanged = false;
  for (const capabilityType of CAPABILITIES.filter((c) => !enabled.has(c))) {
    await api('POST', '/v1/bundleIdCapabilities', {
      data: { type: 'bundleIdCapabilities', attributes: { capabilityType }, relationships: { bundleId: { data: { type: 'bundleIds', id: bundle.id } } } },
    });
    capabilitiesChanged = true;
    console.error(`Turned on ${capabilityType} for ${BUNDLE_ID}`);
  }

  const certificate = (await api('GET', '/v1/certificates?filter[certificateType]=DISTRIBUTION&limit=200')).data
    .find((c) => c.attributes.serialNumber === serial);
  if (!certificate) throw new Error(`Apple Distribution certificate ${serial} is not on the team (revoked?)`);

  const listed = await api('GET', `/v1/bundleIds/${bundle.id}/profiles?limit=200`);
  const profiles = await Promise.all(listed.data.map(async (p) => ({
    ...p,
    certificateIds: (await api('GET', `/v1/profiles/${p.id}/relationships/certificates`)).data.map((c) => c.id),
  })));
  let profile = capabilitiesChanged ? undefined : pickProfile(profiles, certificate.id);

  if (!profile) {
    // A same-named profile would make Xcode's lookup ambiguous; replace it.
    for (const stale of profiles.filter((p) => p.attributes.name === PROFILE_NAME)) {
      await api('DELETE', `/v1/profiles/${stale.id}`);
    }
    profile = (await api('POST', '/v1/profiles', {
      data: {
        type: 'profiles',
        attributes: { name: PROFILE_NAME, profileType: 'IOS_APP_STORE' },
        relationships: {
          bundleId: { data: { type: 'bundleIds', id: bundle.id } },
          certificates: { data: [{ type: 'certificates', id: certificate.id }] },
        },
      },
    })).data;
    console.error(`Created profile "${PROFILE_NAME}" (expires ${profile.attributes.expirationDate.slice(0, 10)})`);
  }

  const full = (await api('GET', `/v1/profiles/${profile.id}?fields[profiles]=profileContent,uuid,expirationDate`)).data;
  writeFileSync(out, Buffer.from(full.attributes.profileContent, 'base64'));
  console.log(full.attributes.uuid);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main(process.argv[2]).catch((err) => {
    console.error(`error: ${err.message}`);
    process.exit(1);
  });
}
