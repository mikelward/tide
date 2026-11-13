// tide's press-and-hold accents: the part with no fcitx5 in it. See
// accents_core.h.

#include "accents_core.h"

#include <cctype>
#include <algorithm>
#include <cstdlib>

namespace tide_accents {

// --- JSON -------------------------------------------------------------------
//
// Enough JSON for the table: a full parser of the grammar, keeping only the
// strings, arrays and objects the table is made of.

namespace {

std::string encode(const std::vector<uint32_t> &cps) {
    std::string out;
    for (uint32_t cp : cps) {
        if (cp < 0x80) {
            out += char(cp);
        } else if (cp < 0x800) {
            out += char(0xc0 | (cp >> 6));
            out += char(0x80 | (cp & 0x3f));
        } else if (cp < 0x10000) {
            out += char(0xe0 | (cp >> 12));
            out += char(0x80 | ((cp >> 6) & 0x3f));
            out += char(0x80 | (cp & 0x3f));
        } else {
            out += char(0xf0 | (cp >> 18));
            out += char(0x80 | ((cp >> 12) & 0x3f));
            out += char(0x80 | ((cp >> 6) & 0x3f));
            out += char(0x80 | (cp & 0x3f));
        }
    }
    return out;
}

struct Value {
    enum Type { Null, Bool, Number, String, Array, Object } type = Null;
    double number = 0;
    std::string string;
    std::vector<Value> array;
    std::vector<std::pair<std::string, Value>> object;
};

class Parser {
public:
    explicit Parser(const std::string &s) : s_(s) {}

    bool parse(Value &out, std::string &error) {
        ws();
        if (!value(out, 0)) {
            error = error_;
            return false;
        }
        ws();
        if (i_ != s_.size()) {
            error = at("text after the JSON");
            return false;
        }
        return true;
    }

private:
    std::string at(const std::string &what) {
        return what + " at byte " + std::to_string(i_);
    }
    bool fail(const std::string &what) {
        if (error_.empty())
            error_ = at(what);
        return false;
    }
    void ws() {
        while (i_ < s_.size() && (s_[i_] == ' ' || s_[i_] == '\t' ||
                                  s_[i_] == '\n' || s_[i_] == '\r'))
            ++i_;
    }
    bool literal(const char *word) {
        std::string w(word);
        if (s_.compare(i_, w.size(), w) != 0)
            return fail("an unknown word");
        i_ += w.size();
        return true;
    }

    bool value(Value &v, int depth) {
        if (depth > 64)
            return fail("nesting too deep");
        if (i_ >= s_.size())
            return fail("the end of the file");
        char c = s_[i_];
        if (c == '{')
            return object(v, depth);
        if (c == '[')
            return array(v, depth);
        if (c == '"') {
            v.type = Value::String;
            return string(v.string);
        }
        if (c == 't') {
            v.type = Value::Bool;
            return literal("true");
        }
        if (c == 'f') {
            v.type = Value::Bool;
            return literal("false");
        }
        if (c == 'n') {
            v.type = Value::Null;
            return literal("null");
        }
        if (c == '-' || (c >= '0' && c <= '9'))
            return number(v);
        return fail("an unexpected character");
    }

    bool number(Value &v) {
        size_t start = i_;
        if (s_[i_] == '-')
            ++i_;
        auto digits = [&] {
            size_t d = i_;
            while (i_ < s_.size() && std::isdigit((unsigned char)s_[i_]))
                ++i_;
            return i_ > d;
        };
        if (!digits())
            return fail("a bad number");
        if (i_ < s_.size() && s_[i_] == '.') {
            ++i_;
            if (!digits())
                return fail("a bad number");
        }
        if (i_ < s_.size() && (s_[i_] == 'e' || s_[i_] == 'E')) {
            ++i_;
            if (i_ < s_.size() && (s_[i_] == '+' || s_[i_] == '-'))
                ++i_;
            if (!digits())
                return fail("a bad number");
        }
        v.type = Value::Number;
        v.number = std::strtod(s_.substr(start, i_ - start).c_str(), nullptr);
        return true;
    }

    bool hex4(uint32_t &cp) {
        if (i_ + 4 > s_.size())
            return fail("a short \\u escape");
        cp = 0;
        for (int k = 0; k < 4; ++k) {
            char c = s_[i_++];
            cp <<= 4;
            if (c >= '0' && c <= '9')
                cp |= c - '0';
            else if (c >= 'a' && c <= 'f')
                cp |= c - 'a' + 10;
            else if (c >= 'A' && c <= 'F')
                cp |= c - 'A' + 10;
            else
                return fail("a bad \\u escape");
        }
        return true;
    }

    bool string(std::string &out) {
        ++i_; // the opening quote
        while (true) {
            if (i_ >= s_.size())
                return fail("an unterminated string");
            unsigned char c = s_[i_];
            if (c == '"') {
                ++i_;
                return true;
            }
            if (c < 0x20)
                return fail("a control character in a string");
            if (c != '\\') {
                out += char(c);
                ++i_;
                continue;
            }
            ++i_;
            if (i_ >= s_.size())
                return fail("an unterminated string");
            char e = s_[i_++];
            switch (e) {
            case '"': out += '"'; break;
            case '\\': out += '\\'; break;
            case '/': out += '/'; break;
            case 'b': out += '\b'; break;
            case 'f': out += '\f'; break;
            case 'n': out += '\n'; break;
            case 'r': out += '\r'; break;
            case 't': out += '\t'; break;
            case 'u': {
                uint32_t cp;
                if (!hex4(cp))
                    return false;
                if (cp >= 0xd800 && cp < 0xdc00) {
                    uint32_t lo;
                    if (s_.compare(i_, 2, "\\u") != 0)
                        return fail("a lone surrogate");
                    i_ += 2;
                    if (!hex4(lo))
                        return false;
                    if (lo < 0xdc00 || lo >= 0xe000)
                        return fail("a lone surrogate");
                    cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
                } else if (cp >= 0xdc00 && cp < 0xe000) {
                    return fail("a lone surrogate");
                }
                out += encode({cp});
                break;
            }
            default:
                return fail("a bad escape");
            }
        }
    }

    bool array(Value &v, int depth) {
        v.type = Value::Array;
        ++i_;
        ws();
        if (i_ < s_.size() && s_[i_] == ']') {
            ++i_;
            return true;
        }
        while (true) {
            Value item;
            ws();
            if (!value(item, depth + 1))
                return false;
            v.array.push_back(std::move(item));
            ws();
            if (i_ >= s_.size())
                return fail("an unterminated array");
            if (s_[i_] == ',') {
                ++i_;
                continue;
            }
            if (s_[i_] == ']') {
                ++i_;
                return true;
            }
            return fail("a missing comma in an array");
        }
    }

    bool object(Value &v, int depth) {
        v.type = Value::Object;
        ++i_;
        ws();
        if (i_ < s_.size() && s_[i_] == '}') {
            ++i_;
            return true;
        }
        while (true) {
            ws();
            if (i_ >= s_.size() || s_[i_] != '"')
                return fail("a missing key in an object");
            std::string key;
            if (!string(key))
                return false;
            ws();
            if (i_ >= s_.size() || s_[i_] != ':')
                return fail("a missing colon in an object");
            ++i_;
            ws();
            Value item;
            if (!value(item, depth + 1))
                return false;
            v.object.emplace_back(std::move(key), std::move(item));
            ws();
            if (i_ >= s_.size())
                return fail("an unterminated object");
            if (s_[i_] == ',') {
                ++i_;
                continue;
            }
            if (s_[i_] == '}') {
                ++i_;
                return true;
            }
            return fail("a missing comma in an object");
        }
    }

    const std::string &s_;
    size_t i_ = 0;
    std::string error_;
};

// The code points of a UTF-8 string, or false if it isn't valid UTF-8.
bool decode(const std::string &s, std::vector<uint32_t> &out) {
    for (size_t i = 0; i < s.size();) {
        unsigned char c = s[i];
        int n;
        uint32_t cp;
        if (c < 0x80) {
            n = 0;
            cp = c;
        } else if ((c & 0xe0) == 0xc0) {
            n = 1;
            cp = c & 0x1f;
        } else if ((c & 0xf0) == 0xe0) {
            n = 2;
            cp = c & 0x0f;
        } else if ((c & 0xf8) == 0xf0) {
            n = 3;
            cp = c & 0x07;
        } else {
            return false;
        }
        if (n > 0 && i + n >= s.size())
            return false;
        for (int k = 1; k <= n; ++k) {
            unsigned char d = s[i + k];
            if ((d & 0xc0) != 0x80)
                return false;
            cp = (cp << 6) | (d & 0x3f);
        }
        out.push_back(cp);
        i += n + 1;
    }
    return true;
}

bool printable(uint32_t cp) {
    return cp >= 0x20 && !(cp >= 0x7f && cp < 0xa0);
}

uint32_t upper(uint32_t cp) {
    if (cp >= 'a' && cp <= 'z')
        return cp - 0x20;
    // Latin-1: à-þ, but not ÷.
    if (cp >= 0xe0 && cp <= 0xfe && cp != 0xf7)
        return cp - 0x20;
    if (cp == 0xff) // ÿ
        return 0x178;
    // Latin Extended-A pairs a capital (even) with its small letter (odd)
    // from Ā to ķ and from Ŋ to ŷ; and the other way round from Ĺ to ň and
    // from Ź to ž.
    if ((cp >= 0x100 && cp <= 0x137) || (cp >= 0x14a && cp <= 0x177))
        return (cp & 1) ? cp - 1 : cp;
    if ((cp >= 0x139 && cp <= 0x148) || (cp >= 0x179 && cp <= 0x17e))
        return (cp & 1) ? cp : cp - 1;
    return cp;
}

std::string trim(const std::string &s) {
    size_t b = s.find_first_not_of(" \t\r");
    if (b == std::string::npos)
        return "";
    size_t e = s.find_last_not_of(" \t\r");
    return s.substr(b, e - b + 1);
}

} // namespace

std::string toUpper(const std::string &text) {
    std::vector<uint32_t> cps;
    if (!decode(text, cps))
        return text;
    for (auto &cp : cps)
        cp = upper(cp);
    return encode(cps);
}

bool parseTable(const std::string &json, Table &out, std::string &error) {
    Value root;
    if (!Parser(json).parse(root, error))
        return false;
    if (root.type != Value::Object) {
        error = "the top level isn't an object";
        return false;
    }
    const Value *version = nullptr, *map = nullptr;
    for (const auto &[k, v] : root.object) {
        if (k == "version")
            version = &v;
        else if (k == "map")
            map = &v;
    }
    if (!version || version->type != Value::Number || version->number != 1) {
        error = "\"version\" isn't 1";
        return false;
    }
    if (!map || map->type != Value::Object) {
        error = "\"map\" isn't an object";
        return false;
    }
    Table table;
    for (const auto &[key, list] : map->object) {
        std::vector<uint32_t> cps;
        if (!decode(key, cps) || cps.size() != 1 || !printable(cps[0])) {
            error = "map key \"" + key + "\" isn't one character";
            return false;
        }
        if (list.type != Value::Array || list.array.empty()) {
            error = "map key \"" + key + "\" isn't a list of accents";
            return false;
        }
        std::vector<std::string> accents;
        for (const auto &item : list.array) {
            std::vector<uint32_t> acps;
            if (item.type != Value::String || item.string.empty() ||
                !decode(item.string, acps)) {
                error = "map key \"" + key + "\" has an accent that isn't text";
                return false;
            }
            for (uint32_t cp : acps) {
                if (!printable(cp)) {
                    error = "map key \"" + key +
                            "\" has an accent that can't be shown";
                    return false;
                }
            }
            accents.push_back(item.string);
        }
        table[key] = std::move(accents);
    }
    out = std::move(table);
    return true;
}

Table mergeTables(const Table &base, const Table &user) {
    Table out = base;
    for (const auto &[key, accents] : user) {
        // The user's small letter replaces the default capital too, unless
        // the user gives the capital as well.
        std::string capital = toUpper(key);
        if (capital != key && !user.count(capital))
            out.erase(capital);
        out[key] = accents;
    }
    return out;
}

std::vector<std::string> lookup(const Table &table, const std::string &text) {
    auto it = table.find(text);
    if (it != table.end())
        return it->second;
    // A capital the table leaves out: the small letter's, in capitals.
    std::vector<uint32_t> cps;
    if (!decode(text, cps) || cps.size() != 1)
        return {};
    for (const auto &[key, accents] : table) {
        if (key != text && toUpper(key) == text) {
            std::vector<std::string> out;
            for (const auto &a : accents)
                out.push_back(toUpper(a));
            return out;
        }
    }
    return {};
}

Settings parseSettings(const std::string &text,
                       std::vector<std::string> &errors) {
    Settings s;
    size_t start = 0;
    int line = 0;
    while (start <= text.size()) {
        size_t end = text.find('\n', start);
        if (end == std::string::npos)
            end = text.size();
        std::string l = text.substr(start, end - start);
        ++line;
        start = end + 1;
        // `#` starts a comment, at the start of a line or after a value.
        size_t hash = l.find('#');
        if (hash != std::string::npos)
            l = l.substr(0, hash);
        l = trim(l);
        if (l.empty())
            continue;
        size_t eq = l.find('=');
        std::string where = "accents.conf line " + std::to_string(line);
        if (eq == std::string::npos) {
            errors.push_back(where + ": no \"=\" in \"" + l + "\"");
            continue;
        }
        std::string key = trim(l.substr(0, eq));
        std::string value = trim(l.substr(eq + 1));
        if (key == "hold_ms") {
            char *rest = nullptr;
            long ms = std::strtol(value.c_str(), &rest, 10);
            if (value.empty() || *rest != '\0' || ms < 50 || ms > 5000) {
                errors.push_back(where + ": hold_ms must be a number of "
                                 "milliseconds from 50 to 5000, not \"" +
                                 value + "\"");
                continue;
            }
            s.holdMs = int(ms);
        } else if (key == "off") {
            std::vector<std::string> off;
            std::string word;
            for (char c : value + " ") {
                if (c == ' ' || c == ',' || c == '\t') {
                    if (!word.empty())
                        off.push_back(word);
                    word.clear();
                } else {
                    word += c;
                }
            }
            s.off = off;
        } else {
            errors.push_back(where + ": unknown setting \"" + key + "\"");
        }
    }
    return s;
}

// --- The state machine -----------------------------------------------------

namespace {

bool isModifier(uint32_t sym) {
    return (sym >= 0xffe1 && sym <= 0xffee) || // Shift_L .. Hyper_R
           (sym >= 0xfe01 && sym <= 0xfe13) || // ISO_Lock .. ISO_Level5_Lock
           sym == 0xff7e;                      // Mode_switch
}

// 1-9 on the main row or the keypad, or 0.
int digit(uint32_t sym) {
    if (sym >= '1' && sym <= '9')
        return int(sym - '0');
    if (sym >= 0xffb1 && sym <= 0xffb9)
        return int(sym - 0xffb0);
    return 0;
}

Action act(Action::Kind kind) { return Action{kind, {}, 0, {}, -1}; }

} // namespace

bool Machine::off(const Context &ctx) const {
    if (ctx.password)
        return true;
    for (const auto &p : settings_->off)
        if (!ctx.program.empty() && p == ctx.program)
            return true;
    return false;
}

void Machine::close(Result &r) {
    if (state_ == State::Held)
        r.actions.push_back(act(Action::CancelTimer));
    if (state_ == State::Shown)
        r.actions.push_back(act(Action::HideCandidates));
    state_ = State::Idle;
    candidates_.clear();
    highlight_ = -1;
}

std::string charBefore(const std::string &text, size_t cursorChars) {
    if (cursorChars == 0)
        return "";
    size_t start = std::string::npos, i = 0, n = 0;
    while (i < text.size() && n < cursorChars) {
        start = i;
        ++i;
        // Skip the character's continuation bytes.
        while (i < text.size() && (uint8_t(text[i]) & 0xc0) == 0x80)
            ++i;
        ++n;
    }
    if (n < cursorChars)
        return "";
    return text.substr(start, i - start);
}

Result Machine::idlePress(const KeyPress &key, const Context &ctx) {
    Result r;
    if (key.otherModifiers || off(ctx))
        return r;
    auto accents = lookup(*table_, key.text);
    if (accents.empty())
        return r;
    // Typed at once, as on macOS; the key itself goes no further, so the app
    // never repeats it.
    r.consume = true;
    consumed_.insert(key.code);
    r.actions.push_back(Action{Action::Commit, key.text, 0, {}, -1});
    Action timer = act(Action::StartTimer);
    timer.ms = settings_->holdMs;
    r.actions.push_back(timer);
    if (int(accents.size()) > kMaxCandidates)
        accents.resize(kMaxCandidates);
    candidates_ = std::move(accents);
    state_ = State::Held;
    heldCode_ = key.code;
    letter_ = key.text;
    heldDown_ = true;
    return r;
}

Result Machine::press(const KeyPress &key, const Context &ctx) {
    // Shift and the rest change nothing on their own.
    if (isModifier(key.sym))
        return {};
    bool sameKeyHeld = heldDown_ && key.code == heldCode_;
    if (sameKeyHeld) {
        // The held letter's own repeats, until it's released: swallowed,
        // after a pick or Esc too, as a client may not mark them.
        Result r;
        r.consume = true;
        return r;
    }
    if (consumed_.count(key.code)) {
        // A key whose press we took and that's still down: whatever it is
        // now, a press of it before its release is a repeat, marked or not.
        Result r;
        r.consume = true;
        return r;
    }
    if (state_ == State::Shown && !key.otherModifiers) {
        int n = int(candidates_.size());
        int d = digit(key.sym);
        if (d >= 1 && d <= n) {
            consumed_.insert(key.code);
            return choose(d - 1, ctx);
        }
        if (key.sym == keysym::Right || key.sym == keysym::Left) {
            if (key.sym == keysym::Right)
                highlight_ = highlight_ < 0 ? 0 : std::min(highlight_ + 1, n - 1);
            else
                highlight_ = highlight_ < 0 ? n - 1 : std::max(highlight_ - 1, 0);
            Result r;
            r.consume = true;
            consumed_.insert(key.code);
            r.actions.push_back(
                Action{Action::ShowCandidates, {}, 0, candidates_, highlight_});
            return r;
        }
        if ((key.sym == keysym::Return || key.sym == keysym::KP_Enter) &&
            highlight_ >= 0) {
            consumed_.insert(key.code);
            return choose(highlight_, ctx);
        }
        if (key.sym == keysym::Escape) {
            Result r;
            r.consume = true;
            consumed_.insert(key.code);
            close(r);
            return r;
        }
    }
    // Any other key: the list closes or the timer stops, the letter stays,
    // and the key is handled as if nothing were held.
    Result r;
    close(r);
    heldDown_ = false;
    Result next = idlePress(key, ctx);
    r.consume = next.consume;
    r.actions.insert(r.actions.end(), next.actions.begin(), next.actions.end());
    return r;
}

Result Machine::release(int code, const Context &) {
    Result r;
    if (heldDown_ && code == heldCode_) {
        heldDown_ = false;
        // Let go before the hold time: the letter is already typed. Once
        // shown, the list stays, as on macOS.
        if (state_ == State::Held)
            close(r);
    }
    if (consumed_.erase(code))
        r.consume = true;
    return r;
}

Result Machine::timerFired(const Context &ctx) {
    Result r;
    if (state_ != State::Held)
        return r;
    if (off(ctx)) {
        close(r);
        return r;
    }
    state_ = State::Shown;
    highlight_ = -1;
    r.actions.push_back(
        Action{Action::ShowCandidates, {}, 0, candidates_, highlight_});
    return r;
}

Result Machine::pick(int index, const Context &ctx) {
    if (state_ != State::Shown || index < 0 ||
        index >= int(candidates_.size()))
        return {};
    return choose(index, ctx);
}

Result Machine::choose(int index, const Context &ctx) {
    Result r;
    r.consume = true;
    std::string accent = candidates_[index];
    close(r);
    // The letter typed on the press makes way for the accent: deleted as
    // surrounding text where the app shows it before the cursor, else with
    // a Backspace.
    r.actions.push_back(act(ctx.beforeCursor == letter_ ? Action::DeleteBefore
                                                         : Action::BackSpace));
    r.actions.push_back(Action{Action::Commit, accent, 0, {}, -1});
    return r;
}

Result Machine::reset() {
    Result r;
    close(r);
    heldDown_ = false;
    consumed_.clear();
    return r;
}

Result Machine::appReset() {
    if (state_ == State::Held)
        return {};
    // The list closes, but the keys still down stay known: their releases
    // come to this context, and until then their presses are repeats.
    Result r;
    close(r);
    return r;
}

} // namespace tide_accents
