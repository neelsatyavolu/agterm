/** The Fly region nearest a client, from Cloudflare's view of the request. */
export function nearestRegion(continent: string | undefined, longitude: number | undefined): string {
  switch (continent) {
    case "EU": case "AF": return "fra";
    case "AS": return longitude !== undefined && longitude > 120 ? "nrt" : "sin";
    case "OC": return "syd";
    case "SA": return "gru";
    default: return longitude !== undefined && longitude < -100 ? "sjc" : "iad";
  }
}
