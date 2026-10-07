// macOS exclusive rename: publish a complete app without replacing another installer’s output.
#include <stdio.h>
#include <sys/stdio.h>

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    if (renamex_np(argv[1], argv[2], RENAME_EXCL) != 0) {
        perror("Cannot publish application without overwriting");
        return 1;
    }
    return 0;
}
