// Stands in for Claude Code in agterm's Move to Cloud self-test (AGTERM_MOVE_CHECK=1, see
// Sources/AgTerm/SelfTestMove.swift). Like Claude it records its session in
// ~/.claude/sessions/<pid>.json (busy, mid-turn) and appends to its transcript in
// ~/.claude/projects/<cwd>/<id>.jsonl, then waits. `--resume <id>` continues a transcript; the
// last other argument is the prompt; `--idle` records the turn as finished. It prints one line
// saying which session it is in, how long the transcript is, the prompt and the OS, so the test
// can tell where it runs and what it remembers.
#include <ctype.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

static char record[PATH_MAX];

static void stop(int signal) {
    (void)signal;
    unlink(record);
    _exit(0);
}

static void make_dirs(char *path) {
    for (char *p = path + 1; *p; p++) {
        if (*p == '/') { *p = 0; mkdir(path, 0700); *p = '/'; }
    }
    mkdir(path, 0700);
}

int main(int argc, char **argv) {
    const char *id = NULL, *prompt = "", *status = "busy";
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--resume") == 0 && i + 1 < argc) id = argv[++i];
        else if (strcmp(argv[i], "--idle") == 0) status = "idle";
        else if (argv[i][0] != '-') prompt = argv[i];
    }
    char fresh[40];
    if (!id) {
        srand((unsigned)time(NULL) ^ (unsigned)getpid());
        snprintf(fresh, sizeof fresh, "%08x-0000-4000-8000-%08x%04x", rand(), rand(), rand() & 0xffff);
        id = fresh;
    }
    const char *home = getenv("HOME");
    char cwd[PATH_MAX], project[PATH_MAX], transcript[PATH_MAX];
    if (!home || !getcwd(cwd, sizeof cwd)) return 1;
    for (char *c = cwd; *c; c++) if (!isalnum((unsigned char)*c)) *c = '-';
    snprintf(project, sizeof project, "%s/.claude/projects/%s", home, cwd);
    make_dirs(project);
    snprintf(transcript, sizeof transcript, "%s/%s.jsonl", project, id);
    char sessions[PATH_MAX];
    snprintf(sessions, sizeof sessions, "%s/.claude/sessions", home);
    make_dirs(sessions);
    snprintf(record, sizeof record, "%s/%d.json", sessions, (int)getpid());
    signal(SIGTERM, stop);
    signal(SIGHUP, stop);
    signal(SIGINT, stop);

    FILE *f = fopen(record, "w");
    if (f) { fprintf(f, "{\"sessionId\":\"%s\",\"status\":\"%s\"}\n", id, status); fclose(f); }
    f = fopen(transcript, "a");
    if (f) { fprintf(f, "{\"prompt\":\"%s\"}\n", prompt); fclose(f); }
    int lines = 0, c;
    f = fopen(transcript, "r");
    if (f) { while ((c = fgetc(f)) != EOF) if (c == '\n') lines++; fclose(f); }
    struct utsname host;
    uname(&host);
    printf("FAKE-CLAUDE session=%s lines=%d prompt=[%s] host=%s\n", id, lines, prompt, host.sysname);
    fflush(stdout);
    for (;;) pause();
}
