// tide's press-and-hold accents: the part with no fcitx5 in it (SPEC.md §8.6).
//
// A state machine fed key presses, releases, the hold timer and candidate
// clicks, which answers with what to do: consume the key or pass it on, and
// a list of actions for tide_accents.cpp to carry out through fcitx5. Plus
// the accent table, in Plasma Keyboard's diacritics format, and the
// settings file.

#ifndef TIDE_ACCENTS_CORE_H
#define TIDE_ACCENTS_CORE_H

#include <cstdint>
#include <map>
#include <set>
#include <string>
#include <vector>

namespace tide_accents {

// The default hold time, in milliseconds.
constexpr int kDefaultHoldMs = 300;

// Programs (fcitx5's InputContext::program()) the accents are off in, by
// default. Empty: on everywhere. A terminal's name here would let its own
// key repeat and Vim's motions run on a held letter.
inline const std::vector<std::string> kDefaultOff = {};

// At most this many accents show: one per digit, 1 to 9.
constexpr int kMaxCandidates = 9;

// A letter's accents, keyed by the letter's text ("e", "E").
using Table = std::map<std::string, std::vector<std::string>>;

// Parses a table in Plasma Keyboard's format:
//   {"version": 1, "map": {"e": ["è", "é"], ...}}
// Other top-level keys (Plasma's "description") are allowed and ignored.
// Returns false, with a message in error, for anything else.
bool parseTable(const std::string &json, Table &out, std::string &error);

// The default table with the user's laid over it. The user's letter wins,
// both cases of it: a user "e" without an "E" drops the default "E" too, so
// the capitals follow the user's list (lookup derives them).
Table mergeTables(const Table &base, const Table &user);

// The accents for a letter's text, or none. A capital the table doesn't
// list gets its small letter's accents in capitals.
std::vector<std::string> lookup(const Table &table, const std::string &text);

// The capital of each Latin-1 and Latin Extended-A letter; anything else
// comes back as it was.
std::string toUpper(const std::string &text);

struct Settings {
    int holdMs = kDefaultHoldMs;
    std::vector<std::string> off = kDefaultOff;
};

// Parses accents.conf: `key = value` lines; `#` starts a comment.
//   hold_ms = 300           how long a letter is held before its accents show
//   off = kitty wezterm     programs the accents are off in, space- or
//                           comma-separated
// A bad line is reported in errors, naming the setting, and skipped, so
// that setting keeps its default.
Settings parseSettings(const std::string &text,
                       std::vector<std::string> &errors);

// What the input context says about itself, at each event.
struct Context {
    bool password = false;          // Password or Sensitive
    bool surroundingText = false;   // can delete text before the cursor
    std::string program;            // may be empty where fcitx5 can't tell
};

// X keysyms the machine knows by number.
namespace keysym {
constexpr uint32_t Left = 0xff51;
constexpr uint32_t Right = 0xff53;
constexpr uint32_t Return = 0xff0d;
constexpr uint32_t KP_Enter = 0xff8d;
constexpr uint32_t Escape = 0xff1b;
constexpr uint32_t BackSpace = 0xff08;
} // namespace keysym

struct KeyPress {
    int code = 0;           // the hardware key, which names it across Shift
    uint32_t sym = 0;       // its keysym, with Shift and Caps Lock applied
    std::string text;       // what it types, with Shift applied ("E")
    bool otherModifiers = false; // Ctrl, Alt, Super, Hyper or Meta held
    bool repeat = false;    // a press from key repeat
};

struct Action {
    enum Kind {
        Commit,          // commit text
        StartTimer,      // start the hold timer for ms
        CancelTimer,
        ShowCandidates,  // show candidates, highlight (-1: none)
        HideCandidates,
        DeleteBefore,    // delete the character before the cursor
                         // (deleteSurroundingText(-1, 1))
        BackSpace,       // send a BackSpace press and release
    };
    Kind kind;
    std::string text;
    int ms = 0;
    std::vector<std::string> candidates;
    int highlight = -1;

    bool operator==(const Action &o) const {
        return kind == o.kind && text == o.text && ms == o.ms &&
               candidates == o.candidates && highlight == o.highlight;
    }
};

struct Result {
    bool consume = false;   // false: the key goes on to the app untouched
    std::vector<Action> actions;
};

// One per input context.
class Machine {
public:
    Machine(const Table *table, const Settings *settings)
        : table_(table), settings_(settings) {}

    Result press(const KeyPress &key, const Context &ctx);
    Result release(int code, const Context &ctx);
    Result timerFired(const Context &ctx);
    // A click on the list's candidate at index.
    Result pick(int index, const Context &ctx);
    // Focus left or the input method was switched.
    Result reset();
    // The app reset the input method. Chromium does after every commit, so
    // one while the letter is held, before its list, is ignored; one with
    // the list up (a click elsewhere) closes it. Either way, keys still
    // down stay known until their releases.
    Result appReset();

    bool showing() const { return state_ == State::Shown; }

private:
    enum class State { Idle, Held, Shown };

    bool off(const Context &ctx) const;
    Result idlePress(const KeyPress &key, const Context &ctx);
    Result choose(int index, const Context &ctx);
    void close(Result &r);

    const Table *table_;
    const Settings *settings_;
    State state_ = State::Idle;
    int heldCode_ = 0;
    bool heldDown_ = false;
    std::vector<std::string> candidates_;
    int highlight_ = -1;
    // Keys whose press was consumed, so their release is too.
    std::set<int> consumed_;
};

} // namespace tide_accents

#endif
