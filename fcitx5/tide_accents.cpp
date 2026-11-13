// tide's press-and-hold accents, as an fcitx5 input method (SPEC.md §8.6).
//
// The glue between fcitx5 and accents_core: it turns fcitx5's key events
// into the machine's, and the machine's actions into fcitx5 calls. What the
// keys do is decided in accents_core, which is tested on its own.

#include "accents_core.h"

#include <fcitx-utils/event.h>
#include <fcitx-utils/key.h>
#include <fcitx-utils/log.h>
#include <fcitx-utils/standardpath.h>
#include <fcitx/addonfactory.h>
#include <fcitx/addonmanager.h>
#include <fcitx/candidatelist.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputcontextmanager.h>
#include <fcitx/inputcontextproperty.h>
#include <fcitx/inputmethodengine.h>
#include <unistd.h>
#include <fcitx/inputpanel.h>
#include <fcitx/instance.h>
#include <fcitx/surroundingtext.h>
#include <fcitx/userinterface.h>

#include <cstdlib>
#include <fstream>
#include <memory>
#include <sstream>

namespace fcitx {

namespace {

namespace ta = tide_accents;

// Where the user's files live: ${XDG_CONFIG_HOME:-~/.config}/tide.
std::string userDir() {
    const char *xdg = std::getenv("XDG_CONFIG_HOME");
    if (xdg && *xdg)
        return std::string(xdg) + "/tide";
    const char *home = std::getenv("HOME");
    return std::string(home ? home : "") + "/.config/tide";
}

// The file's contents, or false if it can't be read. A missing file is
// reported only when it must be there.
bool readFile(const std::string &path, std::string &out, bool required) {
    std::ifstream in(path);
    if (!in) {
        if (required)
            FCITX_ERROR() << "tide-accents: can't read " << path;
        return false;
    }
    std::stringstream ss;
    ss << in.rdbuf();
    if (in.bad()) {
        FCITX_ERROR() << "tide-accents: can't read " << path;
        return false;
    }
    out = ss.str();
    return true;
}

} // namespace

class TideAccentsEngine;

// Each input context's own machine and hold timer.
class TideAccentsState : public InputContextProperty {
public:
    TideAccentsState(const ta::Table *table, const ta::Settings *settings)
        : machine(table, settings) {}
    ta::Machine machine;
    std::unique_ptr<EventSourceTime> timer;
};

class TideAccentsCandidate : public CandidateWord {
public:
    TideAccentsCandidate(TideAccentsEngine *engine, int index,
                         const std::string &text)
        : CandidateWord(Text(text)), engine_(engine), index_(index) {}
    void select(InputContext *ic) const override;

private:
    TideAccentsEngine *engine_;
    int index_;
};

class TideAccentsEngine final : public InputMethodEngineV2 {
public:
    explicit TideAccentsEngine(Instance *instance)
        : instance_(instance),
          factory_([this](InputContext &) {
              return new TideAccentsState(&table_, &settings_);
          }) {
        instance_->inputContextManager().registerProperty("tide-accents-state",
                                                          &factory_);
        reloadConfig();
    }

    // Rereads the table and settings: `fcitx5-remote -r`, or a restart.
    void reloadConfig() override {
        ta::Table table;
        std::string pkg = StandardPath::global().locate(
            StandardPath::Type::PkgData, "tide-accents/accents.json");
        std::string text, error;
        if (pkg.empty()) {
            FCITX_ERROR() << "tide-accents: no tide-accents/accents.json "
                             "in fcitx5's data directories";
        } else if (readFile(pkg, text, true)) {
            if (!ta::parseTable(text, table, error))
                FCITX_ERROR() << "tide-accents: " << pkg << ": " << error;
        }
        std::string user = userDir() + "/accents.json";
        if (readFile(user, text, false)) {
            ta::Table mine;
            if (ta::parseTable(text, mine, error))
                table = ta::mergeTables(table, mine);
            else
                FCITX_ERROR() << "tide-accents: " << user << ": " << error
                              << "; using the default accents";
        }

        // A file with any bad setting is refused whole, naming each one,
        // and the settings in use stay: the defaults at start, or the last
        // good file's on a reload. Half a file could leave accents on in a
        // program it was meant to be off in.
        ta::Settings settings = settings_;
        std::string conf = userDir() + "/accents.conf";
        if (readFile(conf, text, false)) {
            std::vector<std::string> errors;
            ta::Settings parsed = ta::parseSettings(text, errors);
            if (errors.empty()) {
                settings = std::move(parsed);
            } else {
                for (const auto &e : errors)
                    FCITX_ERROR() << "tide-accents: " << conf << ": " << e;
                FCITX_ERROR() << "tide-accents: " << conf
                              << " has bad settings, so none of it is used";
            }
        } else if (access(conf.c_str(), F_OK) != 0) {
            // No file: the defaults. One that exists but can't be read
            // was logged by readFile, and leaves the settings in use.
            settings = ta::Settings();
        }

        // A reload mid-hold would leave a machine pointing at what it held.
        resetAll();
        table_ = std::move(table);
        settings_ = std::move(settings);
    }

    void keyEvent(const InputMethodEntry &, KeyEvent &event) override {
        auto *ic = event.inputContext();
        auto *state = ic->propertyFor(&factory_);
        ta::Context ctx = context(ic);
        ta::Result r;
        if (event.isRelease()) {
            r = state->machine.release(event.rawKey().code(), ctx);
        } else {
            const Key &key = event.key();
            ta::KeyPress press;
            press.code = event.rawKey().code();
            press.sym = key.sym();
            press.text = Key::keySymToUTF8(key.sym());
            press.otherModifiers = key.states().testAny(
                KeyStates{KeyState::Ctrl, KeyState::Alt, KeyState::Super,
                          KeyState::Super2, KeyState::Hyper,
                          KeyState::Hyper2, KeyState::Meta});
            press.repeat = event.rawKey().states().test(KeyState::Repeat);
            r = state->machine.press(press, ctx);
        }
        apply(ic, state, r);
        if (r.consume)
            event.filterAndAccept();
    }

    // Switched to another input method, or focus left.
    void deactivate(const InputMethodEntry &,
                    InputContextEvent &event) override {
        auto *ic = event.inputContext();
        auto *state = ic->propertyFor(&factory_);
        apply(ic, state, state->machine.reset());
    }

    void reset(const InputMethodEntry &, InputContextEvent &event) override {
        auto *ic = event.inputContext();
        auto *state = ic->propertyFor(&factory_);
        apply(ic, state, state->machine.appReset());
    }

    void pick(InputContext *ic, int index) {
        auto *state = ic->propertyFor(&factory_);
        apply(ic, state, state->machine.pick(index, context(ic)));
    }

private:
    static ta::Context context(InputContext *ic) {
        ta::Context ctx;
        auto caps = ic->capabilityFlags();
        ctx.password = caps.testAny(CapabilityFlag::PasswordOrSensitive);
        const auto &text = ic->surroundingText();
        if (caps.test(CapabilityFlag::SurroundingText) && text.isValid())
            ctx.beforeCursor = ta::charBefore(text.text(), text.cursor());
        ctx.program = ic->program();
        return ctx;
    }

    void resetAll() {
        instance_->inputContextManager().foreach([this](InputContext *ic) {
            auto *state = ic->propertyFor(&factory_);
            apply(ic, state, state->machine.reset());
            return true;
        });
    }

    void startTimer(InputContext *ic, TideAccentsState *state, int ms) {
        auto ref = ic->watch();
        state->timer = instance_->eventLoop().addTimeEvent(
            CLOCK_MONOTONIC, now(CLOCK_MONOTONIC) + uint64_t(ms) * 1000, 0,
            [this, ref](EventSourceTime *, uint64_t) {
                auto *ic = ref.get();
                if (!ic)
                    return false;
                auto *state = ic->propertyFor(&factory_);
                // Focus moved on while the letter was held: no list.
                if (!ic->hasFocus())
                    apply(ic, state, state->machine.reset());
                else
                    apply(ic, state, state->machine.timerFired(context(ic)));
                return false;
            });
    }

    void apply(InputContext *ic, TideAccentsState *state,
               const ta::Result &r) {
        for (const auto &a : r.actions) {
            switch (a.kind) {
            case ta::Action::Commit:
                ic->commitString(a.text);
                break;
            case ta::Action::StartTimer:
                startTimer(ic, state, a.ms);
                break;
            case ta::Action::CancelTimer:
                // Disabled rather than freed: this can run in the timer's
                // own callback.
                if (state->timer)
                    state->timer->setEnabled(false);
                break;
            case ta::Action::ShowCandidates:
                show(ic, a.candidates, a.highlight);
                break;
            case ta::Action::HideCandidates:
                ic->inputPanel().reset();
                ic->updateUserInterface(UserInterfaceComponent::InputPanel);
                break;
            case ta::Action::DeleteBefore:
                ic->deleteSurroundingText(-1, 1);
                break;
            case ta::Action::BackSpace:
                ic->forwardKey(Key(FcitxKey_BackSpace), false);
                ic->forwardKey(Key(FcitxKey_BackSpace), true);
                break;
            }
        }
    }

    // fcitx5's own list at the caret, across, numbered 1 to 9.
    void show(InputContext *ic, const std::vector<std::string> &candidates,
              int highlight) {
        auto list = std::make_unique<CommonCandidateList>();
        list->setLayoutHint(CandidateLayoutHint::Horizontal);
        list->setPageSize(ta::kMaxCandidates);
        std::vector<std::string> labels;
        for (int i = 1; i <= ta::kMaxCandidates; ++i)
            labels.push_back(std::to_string(i) + ". ");
        list->setLabels(labels);
        for (size_t i = 0; i < candidates.size(); ++i)
            list->append<TideAccentsCandidate>(this, int(i), candidates[i]);
        list->setGlobalCursorIndex(highlight);
        ic->inputPanel().reset();
        ic->inputPanel().setCandidateList(std::move(list));
        ic->updateUserInterface(UserInterfaceComponent::InputPanel);
    }

    Instance *instance_;
    ta::Table table_;
    ta::Settings settings_;
    FactoryFor<TideAccentsState> factory_;
};

void TideAccentsCandidate::select(InputContext *ic) const {
    engine_->pick(ic, index_);
}

class TideAccentsFactory : public AddonFactory {
public:
    AddonInstance *create(AddonManager *manager) override {
        return new TideAccentsEngine(manager->instance());
    }
};

} // namespace fcitx

FCITX_ADDON_FACTORY(fcitx::TideAccentsFactory)
