// Tests for accents_core: `make test-accents`, or
//   g++ -std=c++17 fcitx5/accents_core.cpp fcitx5/accents_core_test.cpp -o t
//   ./t fcitx5/accents.json

#include "accents_core.h"

#include <fstream>
#include <iostream>
#include <sstream>

using namespace tide_accents;

static int passed = 0, failed = 0;

#define CHECK(cond)                                                          \
    do {                                                                     \
        if (cond) {                                                          \
            ++passed;                                                        \
        } else {                                                             \
            ++failed;                                                        \
            std::cerr << __FILE__ << ":" << __LINE__ << ": FAIL " #cond      \
                      << " (in " << current << ")\n";                        \
        }                                                                    \
    } while (0)

static const char *current = "";

// Key codes, as evdev + 8 would give them; only their identity matters.
enum { KE = 26, KX = 53, K1 = 10, K2 = 11, K9 = 18, KLEFT = 113,
       KRIGHT = 114, KRET = 36, KESC = 9, KSHIFT = 50, KZ = 52 };

static KeyPress key(int code, uint32_t sym, std::string text = "") {
    KeyPress k;
    k.code = code;
    k.sym = sym;
    k.text = std::move(text);
    return k;
}
static KeyPress e() { return key(KE, 'e', "e"); }
static KeyPress E() { return key(KE, 'E', "E"); }
static KeyPress x() { return key(KX, 'x', "x"); }
static KeyPress z() { return key(KZ, 'z', "z"); }
static KeyPress digitKey(int n) { return key(K1 + n - 1, '0' + n, std::to_string(n)); }

static Action commit(const std::string &t) {
    return Action{Action::Commit, t, 0, {}, -1};
}
static Action timer(int ms) { return Action{Action::StartTimer, {}, ms, {}, -1}; }
static Action plain(Action::Kind k) { return Action{k, {}, 0, {}, -1}; }
static Action show(std::vector<std::string> c, int h) {
    return Action{Action::ShowCandidates, {}, 0, std::move(c), h};
}

static const std::vector<std::string> kE = {"è", "é", "ê", "ë", "ē", "ė", "ę"};
static const std::vector<std::string> kECaps = {"È", "É", "Ê", "Ë", "Ē", "Ė", "Ę"};

static Table testTable() {
    Table t;
    t["e"] = kE;
    t["E"] = kECaps;
    t["z"] = {"ž", "ź", "ż"};
    return t;
}

struct Fixture {
    Table table = testTable();
    Settings settings;
    Machine m{&table, &settings};
    Context ctx;
};

// Holds e past the hold time, so its list shows.
static void holdE(Fixture &f) {
    f.m.press(e(), f.ctx);
    f.m.timerFired(f.ctx);
}

static void testTap() {
    current = "tap";
    Fixture f;
    Result r = f.m.press(e(), f.ctx);
    CHECK(r.consume);
    CHECK((r.actions == std::vector<Action>{commit("e"), timer(300)}));
    // Repeats while held are swallowed: no second e.
    KeyPress rep = e();
    rep.repeat = true;
    r = f.m.press(rep, f.ctx);
    CHECK(r.consume);
    CHECK(r.actions.empty());
    // A repeat the client didn't mark is still the same held key.
    r = f.m.press(e(), f.ctx);
    CHECK(r.consume);
    CHECK(r.actions.empty());
    r = f.m.release(KE, f.ctx);
    CHECK(r.consume);
    CHECK((r.actions == std::vector<Action>{plain(Action::CancelTimer)}));
    CHECK(!f.m.showing());
    // A late timer does nothing.
    r = f.m.timerFired(f.ctx);
    CHECK(r.actions.empty());
}

static void testNoAccents() {
    current = "no accents";
    Fixture f;
    Result r = f.m.press(x(), f.ctx);
    CHECK(!r.consume);
    CHECK(r.actions.empty());
    r = f.m.release(KX, f.ctx);
    CHECK(!r.consume);
}

static void testHoldShows() {
    current = "hold shows";
    Fixture f;
    f.m.press(e(), f.ctx);
    Result r = f.m.timerFired(f.ctx);
    CHECK((r.actions == std::vector<Action>{show(kE, -1)}));
    CHECK(f.m.showing());
    // Releasing the letter leaves the list up.
    r = f.m.release(KE, f.ctx);
    CHECK(r.consume);
    CHECK(r.actions.empty());
    CHECK(f.m.showing());
}

static void testDigitPicks() {
    current = "digit picks";
    Fixture f;
    f.ctx.surroundingText = true;
    holdE(f);
    Result r = f.m.press(digitKey(2), f.ctx);
    CHECK(r.consume);
    CHECK((r.actions == std::vector<Action>{plain(Action::HideCandidates),
                                            plain(Action::DeleteBefore),
                                            commit("é")}));
    CHECK(!f.m.showing());
    // The digit's release goes no further either.
    CHECK(f.m.release(K2, f.ctx).consume);
    // And a digit past the list is just a digit.
    Fixture g;
    g.table["z"] = {"ž"};
    g.m.press(z(), g.ctx);
    g.m.timerFired(g.ctx);
    r = g.m.press(digitKey(9), g.ctx);
    CHECK(!r.consume);
    CHECK((r.actions == std::vector<Action>{plain(Action::HideCandidates)}));
}

static void testBackSpaceWithoutSurrounding() {
    current = "backspace without surrounding text";
    Fixture f;
    f.ctx.surroundingText = false;
    holdE(f);
    Result r = f.m.press(digitKey(1), f.ctx);
    CHECK((r.actions == std::vector<Action>{plain(Action::HideCandidates),
                                            plain(Action::BackSpace),
                                            commit("è")}));
}

static void testArrowsAndEnter() {
    current = "arrows and Enter";
    Fixture f;
    holdE(f);
    Result r = f.m.press(key(KRIGHT, keysym::Right), f.ctx);
    CHECK(r.consume);
    CHECK((r.actions == std::vector<Action>{show(kE, 0)}));
    CHECK(f.m.release(KRIGHT, f.ctx).consume);
    r = f.m.press(key(KRIGHT, keysym::Right), f.ctx);
    CHECK((r.actions == std::vector<Action>{show(kE, 1)}));
    f.m.release(KRIGHT, f.ctx);
    r = f.m.press(key(KLEFT, keysym::Left), f.ctx);
    CHECK((r.actions == std::vector<Action>{show(kE, 0)}));
    f.m.release(KLEFT, f.ctx);
    // Left stops at the first.
    r = f.m.press(key(KLEFT, keysym::Left), f.ctx);
    CHECK((r.actions == std::vector<Action>{show(kE, 0)}));
    f.m.release(KLEFT, f.ctx);
    r = f.m.press(key(KRET, keysym::Return), f.ctx);
    CHECK(r.consume);
    CHECK((r.actions == std::vector<Action>{plain(Action::HideCandidates),
                                            plain(Action::BackSpace),
                                            commit("è")}));
    CHECK(f.m.release(KRET, f.ctx).consume);

    // Left first starts from the last; Enter with nothing highlighted is
    // any other key.
    Fixture g;
    holdE(g);
    r = g.m.press(key(KLEFT, keysym::Left), g.ctx);
    CHECK((r.actions == std::vector<Action>{show(kE, int(kE.size()) - 1)}));
    Fixture h;
    holdE(h);
    r = h.m.press(key(KRET, keysym::Return), h.ctx);
    CHECK(!r.consume);
    CHECK((r.actions == std::vector<Action>{plain(Action::HideCandidates)}));
    CHECK(!h.m.release(KRET, h.ctx).consume);
}

static void testEscape() {
    current = "Esc";
    Fixture f;
    holdE(f);
    Result r = f.m.press(key(KESC, keysym::Escape), f.ctx);
    CHECK(r.consume);
    CHECK((r.actions == std::vector<Action>{plain(Action::HideCandidates)}));
    CHECK(!f.m.showing());
    CHECK(f.m.release(KESC, f.ctx).consume);
    // Esc with no list is the app's.
    r = f.m.press(key(KESC, keysym::Escape), f.ctx);
    CHECK(!r.consume);
}

static void testOtherKey() {
    current = "other key";
    Fixture f;
    holdE(f);
    f.m.release(KE, f.ctx);
    // x closes the list and goes on to the app.
    Result r = f.m.press(x(), f.ctx);
    CHECK(!r.consume);
    CHECK((r.actions == std::vector<Action>{plain(Action::HideCandidates)}));
    CHECK(!f.m.showing());
    // A letter with accents closes it and starts its own.
    holdE(f);
    f.m.release(KE, f.ctx);
    r = f.m.press(z(), f.ctx);
    CHECK(r.consume);
    CHECK((r.actions == std::vector<Action>{plain(Action::HideCandidates),
                                            commit("z"), timer(300)}));
    // The same letter again, once released, types another.
    Fixture g;
    holdE(g);
    g.m.release(KE, g.ctx);
    r = g.m.press(e(), g.ctx);
    CHECK(r.consume);
    CHECK((r.actions == std::vector<Action>{plain(Action::HideCandidates),
                                            commit("e"), timer(300)}));
}

static void testOtherKeyBeforeTimer() {
    current = "other key before the timer";
    Fixture f;
    f.m.press(e(), f.ctx);
    Result r = f.m.press(x(), f.ctx);
    CHECK(!r.consume);
    CHECK((r.actions == std::vector<Action>{plain(Action::CancelTimer)}));
    // The letter's release is still ours.
    CHECK(f.m.release(KE, f.ctx).consume);
    CHECK(f.m.timerFired(f.ctx).actions.empty());
}

static void testShift() {
    current = "Shift";
    Fixture f;
    // Shift's own press changes nothing, held or not.
    Result r = f.m.press(key(KSHIFT, 0xffe1), f.ctx);
    CHECK(!r.consume);
    CHECK(r.actions.empty());
    r = f.m.press(E(), f.ctx);
    CHECK((r.actions == std::vector<Action>{commit("E"), timer(300)}));
    r = f.m.press(key(KSHIFT, 0xffe2), f.ctx);
    CHECK(r.actions.empty());
    r = f.m.timerFired(f.ctx);
    CHECK((r.actions == std::vector<Action>{show(kECaps, -1)}));
    // Shift let go before the letter: the release is still the letter's.
    CHECK(f.m.release(KE, f.ctx).consume);
    CHECK(f.m.showing());
}

static void testDerivedCapitals() {
    current = "derived capitals";
    Table t;
    t["z"] = {"ž", "ź", "ż"};
    t["y"] = {"ÿ"};
    CHECK((lookup(t, "Z") == std::vector<std::string>{"Ž", "Ź", "Ż"}));
    CHECK((lookup(t, "Y") == std::vector<std::string>{"Ÿ"}));
    CHECK(lookup(t, "Q").empty());
    CHECK(toUpper("àéîõüçñøœłšžåæ") == "ÀÉÎÕÜÇÑØŒŁŠŽÅÆ");
    CHECK(toUpper("ß") == "ß");
}

static void testPassThrough() {
    current = "pass through";
    {
        Fixture f;
        f.ctx.password = true;
        Result r = f.m.press(e(), f.ctx);
        CHECK(!r.consume);
        CHECK(r.actions.empty());
        CHECK(!f.m.release(KE, f.ctx).consume);
    }
    {
        Fixture f;
        f.settings.off = {"kitty", "org.wezfurlong.wezterm"};
        f.ctx.program = "kitty";
        Result r = f.m.press(e(), f.ctx);
        CHECK(!r.consume);
        CHECK(r.actions.empty());
        f.ctx.program = "gedit";
        r = f.m.press(e(), f.ctx);
        CHECK(r.consume);
    }
    {
        Fixture f;
        KeyPress ctrlE = e();
        ctrlE.otherModifiers = true;
        Result r = f.m.press(ctrlE, f.ctx);
        CHECK(!r.consume);
        CHECK(r.actions.empty());
        // Ctrl+digit with the list up closes it and goes to the app.
        holdE(f);
        KeyPress ctrl1 = digitKey(1);
        ctrl1.otherModifiers = true;
        r = f.m.press(ctrl1, f.ctx);
        CHECK(!r.consume);
        CHECK((r.actions == std::vector<Action>{plain(Action::HideCandidates)}));
    }
    {
        // The default list leaves it on everywhere.
        Settings s;
        CHECK(s.off.empty());
        CHECK(s.holdMs == 300);
    }
}

static void testClick() {
    current = "click";
    Fixture f;
    f.ctx.surroundingText = true;
    // A click with no list does nothing.
    CHECK(f.m.pick(0, f.ctx).actions.empty());
    holdE(f);
    CHECK(f.m.pick(99, f.ctx).actions.empty());
    Result r = f.m.pick(6, f.ctx);
    CHECK((r.actions == std::vector<Action>{plain(Action::HideCandidates),
                                            plain(Action::DeleteBefore),
                                            commit("ę")}));
}

// After a pick or Esc, the letter may still be held: its repeats, marked or
// not, type nothing until it's released.
static void testHeldAfterClose() {
    current = "held after close";
    for (int how = 0; how < 3; how++) {
        Fixture f;
        f.ctx.surroundingText = true;
        holdE(f);
        if (how == 0)
            f.m.pick(1, f.ctx);
        else if (how == 1)
            f.m.press(digitKey(1), f.ctx);
        else
            f.m.press(key(KESC, keysym::Escape), f.ctx);
        Result r = f.m.press(e(), f.ctx);
        CHECK(r.consume);
        CHECK(r.actions.empty());
        CHECK(f.m.release(KE, f.ctx).consume);
        // Once released, a new press is a new letter.
        r = f.m.press(e(), f.ctx);
        CHECK((r.actions == std::vector<Action>{commit("e"), timer(300)}));
    }
}

// A letter whose press was taken stays swallowed until its release, even
// after another key took over: a client may not mark its repeats.
static void testHeldUnderAnotherKey() {
    current = "held under another key";
    Fixture f;
    f.m.press(e(), f.ctx);
    f.m.press(x(), f.ctx);
    Result r = f.m.press(e(), f.ctx);
    CHECK(r.consume);
    CHECK(r.actions.empty());
    // As does a second letter with accents over the first.
    Fixture g;
    g.m.press(e(), g.ctx);
    g.m.press(z(), g.ctx);
    r = g.m.press(e(), g.ctx);
    CHECK(r.consume);
    CHECK(r.actions.empty());
    // Released, it's a letter again, ending z's hold.
    g.m.release(KE, g.ctx);
    r = g.m.press(e(), g.ctx);
    CHECK((r.actions == std::vector<Action>{plain(Action::CancelTimer), commit("e"), timer(300)}));
}

static void testReset() {
    current = "reset";
    Fixture f;
    holdE(f);
    Result r = f.m.reset();
    CHECK((r.actions == std::vector<Action>{plain(Action::HideCandidates)}));
    CHECK(!f.m.showing());
    Fixture g;
    g.m.press(e(), g.ctx);
    r = g.m.reset();
    CHECK((r.actions == std::vector<Action>{plain(Action::CancelTimer)}));
    CHECK(g.m.timerFired(g.ctx).actions.empty());
}

static void testAppReset() {
    current = "app reset";
    // Chromium resets after the letter's commit: the hold goes on.
    Fixture f;
    f.m.press(e(), f.ctx);
    Result r = f.m.appReset();
    CHECK(r.actions.empty());
    r = f.m.timerFired(f.ctx);
    CHECK((r.actions == std::vector<Action>{show(kE, -1)}));
    // With the list up, it closes it.
    r = f.m.appReset();
    CHECK((r.actions == std::vector<Action>{plain(Action::HideCandidates)}));
    CHECK(!f.m.showing());
    // It forgets no key that's still down: after a pick, Chromium resets
    // again, and the held letter's repeats still type nothing.
    Fixture g;
    g.ctx.surroundingText = true;
    holdE(g);
    g.m.pick(1, g.ctx);
    g.m.appReset();
    r = g.m.press(e(), g.ctx);
    CHECK(r.consume);
    CHECK(r.actions.empty());
    g.m.release(KE, g.ctx);
    r = g.m.press(e(), g.ctx);
    CHECK((r.actions == std::vector<Action>{commit("e"), timer(300)}));
}

static void testNineAtMost() {
    current = "nine at most";
    Fixture f;
    f.table["z"] = {"1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11"};
    f.m.press(z(), f.ctx);
    Result r = f.m.timerFired(f.ctx);
    CHECK(r.actions.size() == 1 && r.actions[0].candidates.size() == 9);
}

static void testParseTable() {
    current = "parse table";
    Table t;
    std::string err;
    CHECK(parseTable(R"({"version": 1, "description": "x \"q\" é",
        "map": {"e": ["è", "é"], "ß": ["😀"]}})",
                     t, err));
    CHECK((t["e"] == std::vector<std::string>{"è", "é"}));
    CHECK((t["ß"] == std::vector<std::string>{"😀"}));

    const char *bad[] = {
        "",
        "[]",
        R"({"map": {"e": ["é"]}})",
        R"({"version": 2, "map": {"e": ["é"]}})",
        R"({"version": 1})",
        R"({"version": 1, "map": []})",
        R"({"version": 1, "map": {"ee": ["é"]}})",
        R"({"version": 1, "map": {"e": "é"}})",
        R"({"version": 1, "map": {"e": []}})",
        R"({"version": 1, "map": {"e": [""]}})",
        R"({"version": 1, "map": {"e": [1]}})",
        R"({"version": 1, "map": {"e": ["\u0007"]}})",
        R"({"version": 1, "map": {"e": ["é"]}} x)",
        R"({"version": 1, "map": {"e": ["é",]}})",
        R"({"version": 1, "map": {"e": ["\ud800"]}})",
        "{\"version\": 1, \"map\": {\"e\": [\"\xff\"]}}",
    };
    for (const char *json : bad) {
        Table keep = {{"a", {"à"}}};
        std::string error;
        bool ok = parseTable(json, keep, error);
        CHECK(!ok);
        CHECK(!error.empty());
        // A bad file leaves the table as it was.
        CHECK(keep.size() == 1 && keep.count("a"));
        if (ok)
            std::cerr << "  accepted: " << json << "\n";
    }
}

static void testMerge() {
    current = "merge";
    Table base = testTable();
    Table user;
    user["e"] = {"é"};
    user["q"] = {"ʠ"};
    Table m = mergeTables(base, user);
    CHECK((m["e"] == std::vector<std::string>{"é"}));
    CHECK((m["q"] == std::vector<std::string>{"ʠ"}));
    // The user's e replaces the default E too: capitals follow it.
    CHECK((lookup(m, "E") == std::vector<std::string>{"É"}));
    // Untouched letters keep the default.
    CHECK((m["z"] == base["z"]));
    // A user capital of its own stays.
    user["E"] = {"Ê"};
    m = mergeTables(base, user);
    CHECK((lookup(m, "E") == std::vector<std::string>{"Ê"}));
    // Only a capital: the default small letter stays.
    Table capsOnly;
    capsOnly["E"] = {"Ë"};
    m = mergeTables(base, capsOnly);
    CHECK((m["e"] == kE));
    CHECK((m["E"] == std::vector<std::string>{"Ë"}));
}

static void testSettings() {
    current = "settings";
    std::vector<std::string> errors;
    Settings s = parseSettings("# comment\n\nhold_ms = 450\noff = kitty, "
                               "org.wezfurlong.wezterm  foot\n",
                               errors);
    CHECK(errors.empty());
    CHECK(s.holdMs == 450);
    CHECK((s.off == std::vector<std::string>{"kitty", "org.wezfurlong.wezterm",
                                             "foot"}));
    errors.clear();
    s = parseSettings("hold_ms = 300           # 50 to 5000\n"
                      "off = kitty, foot       # by space or comma\n",
                      errors);
    CHECK(errors.empty());
    CHECK(s.holdMs == 300);
    CHECK((s.off == std::vector<std::string>{"kitty", "foot"}));
    errors.clear();
    s = parseSettings("hold_ms = soon\nhold_ms=10\nspeed = 3\nnonsense\noff =\n",
                      errors);
    CHECK(errors.size() == 4);
    CHECK(s.holdMs == kDefaultHoldMs);
    CHECK(s.off.empty());
    bool named = errors.size() == 4 &&
                 errors[0].find("hold_ms") != std::string::npos &&
                 errors[2].find("speed") != std::string::npos;
    CHECK(named);
}

static void testShippedTable(const char *path) {
    current = "shipped table";
    std::ifstream in(path);
    CHECK(in.good());
    std::stringstream ss;
    ss << in.rdbuf();
    Table t;
    std::string err;
    CHECK(parseTable(ss.str(), t, err));
    if (!err.empty())
        std::cerr << "  " << path << ": " << err << "\n";
    // macOS's order.
    CHECK((t["e"] == std::vector<std::string>{"è", "é", "ê", "ë", "ē", "ė", "ę"}));
    CHECK((t["a"] == std::vector<std::string>{"à", "á", "â", "ä", "æ", "ã", "å", "ā"}));
    // l stays plain, so Vim's h, j, k and l never open a list.
    for (const char *k : {"h", "j", "k", "l", "H", "J", "K", "L"})
        CHECK(lookup(t, k).empty());
    // Each listed capital is its small letter's list in capitals, where
    // there is one (ß has none).
    for (const auto &[key, accents] : t) {
        std::string cap = toUpper(key);
        if (cap == key || !t.count(cap))
            continue;
        const auto &caps = t[cap];
        CHECK(caps.size() == accents.size());
        for (size_t i = 0; i < accents.size() && i < caps.size(); ++i)
            if (accents[i] != "ß")
                CHECK(toUpper(accents[i]) == caps[i]);
        CHECK(int(accents.size()) <= kMaxCandidates);
    }
}

int main(int argc, char **argv) {
    testTap();
    testNoAccents();
    testHoldShows();
    testDigitPicks();
    testBackSpaceWithoutSurrounding();
    testArrowsAndEnter();
    testEscape();
    testOtherKey();
    testOtherKeyBeforeTimer();
    testShift();
    testDerivedCapitals();
    testPassThrough();
    testClick();
    testHeldAfterClose();
    testHeldUnderAnotherKey();
    testReset();
    testAppReset();
    testNineAtMost();
    testParseTable();
    testMerge();
    testSettings();
    testShippedTable(argc > 1 ? argv[1] : "fcitx5/accents.json");
    std::cout << "accents_core_test: " << passed << " passed, " << failed
              << " failed\n";
    return failed ? 1 : 0;
}
