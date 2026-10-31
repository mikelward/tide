// Tests for generate.mjs, on small pieces of Unicode's own files.
import { test } from "node:test";
import assert from "node:assert/strict";
import { generate, parseEmoji, parseSymbols, plainName } from "./generate.mjs";

const EMOJI_TEST = `# emoji-test.txt
# Version: 16.0

# group: Smileys & Emotion
1F600                                                  ; fully-qualified     # 😀 E1.0 grinning face
# group: People & Body
1F937                                                  ; fully-qualified     # 🤷 E3.0 person shrugging
1F937 1F3FB                                            ; fully-qualified     # 🤷🏻 E3.0 person shrugging: light skin tone
# group: Component
1F3FB                                                  ; component           # 🏻 E1.0 light skin tone
# group: Symbols
2B06 FE0F                                              ; fully-qualified     # ⬆️ E0.6 up arrow
2B06                                                   ; unqualified         # ⬆ E0.6 up arrow
# group: Flags
1F1E8 1F1EE                                            ; fully-qualified     # 🇨🇮 E2.0 flag: Côte d’Ivoire
`;

const UNICODE_DATA = `0009;<control>;Cc;0;S;;;;;N;CHARACTER TABULATION;;;;
00C9;LATIN CAPITAL LETTER E WITH ACUTE;Lu;0;L;0045 0301;;;;N;;;;00E9;
00E9;LATIN SMALL LETTER E WITH ACUTE;Ll;0;L;0065 0301;;;;N;;;00C9;;00C9
0301;COMBINING ACUTE ACCENT;Mn;230;NSM;;;;;N;;;;;
2014;EM DASH;Pd;0;ON;;;;;N;;;;;
2192;RIGHTWARDS ARROW;Sm;0;ON;;;;;N;RIGHT ARROW;;;;
2B06;UPWARDS BLACK ARROW;So;0;ON;;;;;N;;;;;
`;

test("names are plain lowercase ASCII", () => {
    assert.equal(plainName("flag: Côte d’Ivoire"), "flag: cote d'ivoire");
    assert.equal(plainName("LATIN SMALL LETTER E WITH ACUTE"), "latin small letter e with acute");
});

test("emoji: fully-qualified only, no skin tones or components", () => {
    assert.deepEqual(parseEmoji(EMOJI_TEST).map((e) => [e.char, e.name, e.group]), [
        ["😀", "grinning face", "Smileys & Emotion"],
        ["🤷", "person shrugging", "People & Body"],
        ["⬆️", "up arrow", "Symbols"],
        ["🇨🇮", "flag: cote d'ivoire", "Flags"],
    ]);
});

test("symbols: graphic characters in the blocks, small letters before capitals", () => {
    assert.deepEqual(parseSymbols(UNICODE_DATA, new Set()).map((s) => s.char), ["é", "É", "—", "→"]);
    assert.deepEqual(parseSymbols(UNICODE_DATA, new Set(["→"])).map((s) => s.char), ["é", "É", "—"]);
});

test("the file: a header, the symbols, then the emoji, each once", () => {
    const out = generate(EMOJI_TEST, UNICODE_DATA);
    const lines = out.trimEnd().split("\n");
    assert.match(lines[0], /^# /);
    assert.ok(lines.some((l) => /Unicode 16\.0/.test(l)));
    assert.ok(lines.some((l) => /Unicode License v3/.test(l)));
    const rows = lines.filter((l) => !l.startsWith("#"));
    assert.deepEqual(rows.map((r) => r.split("\t")[0]), ["é", "É", "—", "→", "😀", "🤷", "⬆️", "🇨🇮"]);
    assert.ok(rows.every((r) => r.split("\t").length === 3));
});
