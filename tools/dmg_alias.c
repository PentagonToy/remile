#include <CoreServices/CoreServices.h>
#include <stdio.h>

/* Finder's picture-background record uses the legacy Alias Manager format. */
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    AliasHandle alias = NULL;
    OSStatus status = FSNewAliasFromPath(NULL, argv[1], 0, &alias, NULL);
    if (status != noErr || alias == NULL) {
        fprintf(stderr, "Could not create the DMG background alias (%d).\n", (int)status);
        return 1;
    }
    FILE *output = fopen(argv[2], "wb");
    if (!output) { DisposeHandle((Handle)alias); return 1; }
    size_t length = GetAliasSize(alias);
    size_t written = fwrite(*alias, 1, length, output);
    int closeResult = fclose(output);
    DisposeHandle((Handle)alias);
    return written == length && closeResult == 0 ? 0 : 1;
}
