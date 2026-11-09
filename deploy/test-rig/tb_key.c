// SPDX-License-Identifier: GPL-2.0
// Minimal keyboard injector for the Denial/TB710FU test rig.
// Commands on stdin:
//   key NAME            (press+release, e.g. "key enter")
//   combo MOD+KEY       (MOD: ctrl, shift, alt; e.g. "combo ctrl+l")
//   type TEXT           (printable ASCII subset below)
//   sleep MS

#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int fd = -1;

static void die(const char *what)
{
    perror(what);
    exit(1);
}

static void emit(int type, int code, int value)
{
    struct input_event ev = { .type = type, .code = code, .value = value };
    if (write(fd, &ev, sizeof(ev)) != sizeof(ev))
        die("write");
}

static void syn(void)
{
    emit(EV_SYN, SYN_REPORT, 0);
}

static int name_to_code(const char *name)
{
    static const struct { const char *n; int c; } map[] = {
        {"a", KEY_A}, {"b", KEY_B}, {"c", KEY_C}, {"d", KEY_D}, {"e", KEY_E},
        {"f", KEY_F}, {"g", KEY_G}, {"h", KEY_H}, {"i", KEY_I}, {"j", KEY_J},
        {"k", KEY_K}, {"l", KEY_L}, {"m", KEY_M}, {"n", KEY_N}, {"o", KEY_O},
        {"p", KEY_P}, {"q", KEY_Q}, {"r", KEY_R}, {"s", KEY_S}, {"t", KEY_T},
        {"u", KEY_U}, {"v", KEY_V}, {"w", KEY_W}, {"x", KEY_X}, {"y", KEY_Y},
        {"z", KEY_Z}, {"0", KEY_0}, {"1", KEY_1}, {"2", KEY_2}, {"3", KEY_3},
        {"4", KEY_4}, {"5", KEY_5}, {"6", KEY_6}, {"7", KEY_7}, {"8", KEY_8},
        {"9", KEY_9}, {"enter", KEY_ENTER}, {"esc", KEY_ESC}, {"tab", KEY_TAB},
        {"space", KEY_SPACE}, {"slash", KEY_SLASH}, {"dot", KEY_DOT},
        {"ctrl", KEY_LEFTCTRL}, {"shift", KEY_LEFTSHIFT}, {"alt", KEY_LEFTALT},
        {"super", KEY_LEFTMETA}, {"left", KEY_LEFT}, {"right", KEY_RIGHT},
        {"up", KEY_UP}, {"down", KEY_DOWN}, {"home", KEY_HOME}, {"end", KEY_END},
        {"backspace", KEY_BACKSPACE}, {"delete", KEY_DELETE},
        {"pgup", KEY_PAGEUP}, {"pgdown", KEY_PAGEDOWN},
        {"f5", KEY_F5}, {"f11", KEY_F11}, {"f12", KEY_F12},
        {"volumeup", KEY_VOLUMEUP}, {"volumedown", KEY_VOLUMEDOWN}, {"mute", KEY_MUTE}, {"playpause", KEY_PLAYPAUSE},
        {"minus", KEY_MINUS}, {"equal", KEY_EQUAL}, {"semicolon", KEY_SEMICOLON},
        {"apostrophe", KEY_APOSTROPHE}, {"comma", KEY_COMMA}, {"lbracket", KEY_LEFTBRACE},
        {"rbracket", KEY_RIGHTBRACE}, {"backslash", KEY_BACKSLASH},
    };
    for (size_t i = 0; i < sizeof(map) / sizeof(map[0]); i++)
        if (!strcmp(map[i].n, name))
            return map[i].c;
    return -1;
}

static void key_down(int code) { emit(EV_KEY, code, 1); }
static void key_up(int code) { emit(EV_KEY, code, 0); }

static void tap(int code)
{
    key_down(code);
    syn();
    usleep(20000);
    key_up(code);
    syn();
    usleep(20000);
}

static void combo(const char *mods, const char *key)
{
    int m[4], nm = 0;
    char buf[64];
    snprintf(buf, sizeof(buf), "%s", mods);
    for (char *p = strtok(buf, "+"); p && nm < 4; p = strtok(NULL, "+")) {
        int c = name_to_code(p);
        if (c >= 0)
            m[nm++] = c;
    }
    int k = name_to_code(key);
    if (k < 0) { fprintf(stderr, "bad key %s\n", key); return; }
    for (int i = 0; i < nm; i++) key_down(m[i]);
    key_down(k);
    syn();
    usleep(30000);
    key_up(k);
    for (int i = nm - 1; i >= 0; i--) key_up(m[i]);
    syn();
    usleep(30000);
}

static int char_key(char ch, int *shift)
{
    static const int letters[26] = {
        KEY_A, KEY_B, KEY_C, KEY_D, KEY_E, KEY_F, KEY_G, KEY_H, KEY_I,
        KEY_J, KEY_K, KEY_L, KEY_M, KEY_N, KEY_O, KEY_P, KEY_Q, KEY_R,
        KEY_S, KEY_T, KEY_U, KEY_V, KEY_W, KEY_X, KEY_Y, KEY_Z,
    };
    static const int digits[10] = {
        KEY_0, KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9,
    };
    *shift = 0;
    if (ch >= 'a' && ch <= 'z') return letters[ch - 'a'];
    if (ch >= 'A' && ch <= 'Z') { *shift = 1; return letters[ch - 'A']; }
    if (ch >= '0' && ch <= '9') return digits[ch - '0'];
    switch (ch) {
    case ' ': return KEY_SPACE;
    case '/': return KEY_SLASH;
    case '.': return KEY_DOT;
    case ',': return KEY_COMMA;
    case '-': return KEY_MINUS;
    case '_': *shift = 1; return KEY_MINUS;
    case ':': *shift = 1; return KEY_SEMICOLON;
    case ';': return KEY_SEMICOLON;
    case '=': return KEY_EQUAL;
    case '+': *shift = 1; return KEY_EQUAL;
    case '?': *shift = 1; return KEY_SLASH;
    case '!': *shift = 1; return KEY_1;
    case '@': *shift = 1; return KEY_2;
    case '#': *shift = 1; return KEY_3;
    case '$': *shift = 1; return KEY_4;
    case '%': *shift = 1; return KEY_5;
    case '^': *shift = 1; return KEY_6;
    case '&': *shift = 1; return KEY_7;
    case '*': *shift = 1; return KEY_8;
    case '(': *shift = 1; return KEY_9;
    case ')': *shift = 1; return KEY_0;
    case '\\': return KEY_BACKSLASH;
    }
    return -1;
}

static void type_text(const char *text)
{
    for (const char *p = text; *p; p++) {
        int shift;
        int code = char_key(*p, &shift);
        if (code < 0) continue;
        if (shift) key_down(KEY_LEFTSHIFT);
        tap(code);
        if (shift) key_up(KEY_LEFTSHIFT);
        syn();
    }
}

static void setup(void)
{
    struct uinput_setup setup = { 0 };

    fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (fd < 0)
        die("open /dev/uinput");
    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    ioctl(fd, UI_SET_EVBIT, EV_SYN);
    for (int c = KEY_ESC; c <= KEY_MICMUTE; c++)
        if (c != 255)
            ioctl(fd, UI_SET_KEYBIT, c);
    snprintf(setup.name, UINPUT_MAX_NAME_SIZE, "tb-key-inject");
    setup.id.bustype = BUS_VIRTUAL;
    setup.id.vendor = 0x1;
    setup.id.product = 0x2;
    setup.id.version = 1;
    if (ioctl(fd, UI_DEV_SETUP, &setup) < 0)
        die("UI_DEV_SETUP");
    if (ioctl(fd, UI_DEV_CREATE) < 0)
        die("UI_DEV_CREATE");
    usleep(1500000);
}

int main(void)
{
    char line[1024];

    setup();
    while (fgets(line, sizeof(line), stdin)) {
        line[strcspn(line, "\n")] = 0;
        if (!line[0] || line[0] == '#')
            continue;
        if (!strncmp(line, "sleep ", 6)) {
            usleep(atoi(line + 6) * 1000);
        } else if (!strncmp(line, "type ", 5)) {
            type_text(line + 5);
        } else if (!strncmp(line, "combo ", 6)) {
            char mods[64], key[32];
            if (sscanf(line + 6, "%63[^+]+%31s", mods, key) == 2)
                combo(mods, key);
            else
                fprintf(stderr, "bad combo\n");
        } else if (!strncmp(line, "key ", 4)) {
            int c = name_to_code(line + 4);
            if (c >= 0) tap(c); else fprintf(stderr, "bad key\n");
        } else {
            fprintf(stderr, "bad command: %s\n", line);
        }
    }
    ioctl(fd, UI_DEV_DESTROY);
    close(fd);
    return 0;
}
