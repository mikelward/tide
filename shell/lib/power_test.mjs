// Tests for power.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DEFAULTS, hasProfilesDaemon, inhibitCommand, lidLabel, loadPowerSettings, powerLua, steppedLid, withSetting } from "./power.mjs";

test("closing the lid suspends by default, as logind does, with nothing held", () => {
    assert.deepEqual(loadPowerSettings(null, null), { settings: { lidClose: "suspend" }, errors: [] });
    assert.deepEqual(inhibitCommand(DEFAULTS), ["systemctl", "--user", "stop", "tide-lid-inhibit.service"]);
});

test("Lock and Do nothing hold logind's lid switch, and conf reads which", () => {
    assert.deepEqual(inhibitCommand({ lidClose: "lock" }), ["systemctl", "--user", "start", "tide-lid-inhibit.service"]);
    assert.deepEqual(inhibitCommand({ lidClose: "nothing" }), ["systemctl", "--user", "start", "tide-lid-inhibit.service"]);
    assert.match(powerLua({ lidClose: "lock" }), /\nreturn \{\n    lid_close = "lock",\n\}\n$/);
});

test("a bad setting is an error at load naming it, and the last good stays", () => {
    const good = { lidClose: "lock" };
    for (const [text, why] of [
        ['{"lidClose": "hibernate"}', /lidClose must be suspend, lock, nothing, not "hibernate"/],
        ['{"lid": "lock"}', /"lid" isn't a setting/],
        ["[]", /expected an object/],
        ["{", /^power\.local\.json: line 1/],
    ]) {
        const r = loadPowerSettings(null, text, good);
        assert.equal(r.settings, good, text);
        assert.match(r.errors[0], why, text);
    }
    assert.equal(loadPowerSettings('{"lidClose": "lock"}', '{"lidClose": "nothing"}').settings.lidClose, "nothing");
});

test("a change writes only the local file and refuses a bad value", () => {
    assert.deepEqual(JSON.parse(withSetting(null, "lidClose", "lock").text), { lidClose: "lock" });
    assert.match(withSetting(null, "lidClose", "off").error, /lidClose must be/);
    assert.match(withSetting("{", "lidClose", "lock").error, /^power\.local\.json: /);
});

test("power-profiles-daemon is there when either of its names is, running or activatable", () => {
    assert.equal(hasProfilesDaemon("org.freedesktop.UPower 812 upowerd root :1.9 upower.service - -\nnet.hadess.PowerProfiles 640 power-profiles- root :1.5 power-profiles-daemon.service - -\n"), true);
    assert.equal(hasProfilesDaemon("org.freedesktop.UPower.PowerProfiles - - - (activatable) - - -\n"), true);
    assert.equal(hasProfilesDaemon("org.freedesktop.UPower 812 upowerd root :1.9 upower.service - -\n"), false);
    assert.equal(hasProfilesDaemon(""), false);
});

test("the lid's choices step and stop at either end", () => {
    assert.equal(steppedLid("suspend", 1), "lock");
    assert.equal(steppedLid("nothing", 1), "nothing");
    assert.equal(steppedLid("suspend", -1), "suspend");
    assert.equal(lidLabel("nothing"), "Do nothing");
});
