// Tests for unicode.mjs, the generated module: what it says it's from, and
// that its classes are well made and mean what SPEC.md §16 says. Nothing
// here regenerates it, so the host's own Unicode tables don't count.
import { test } from "node:test";
import assert from "node:assert/strict";
import { PIN, categories, module } from "../unicode/generate.mjs";
import { DIGIT, SOURCE_SHA256, UNICODE_VERSION, WORD } from "./unicode.mjs";

test("the classes are from the pinned UnicodeData.txt", () => {
    assert.equal(UNICODE_VERSION, PIN.version);
    assert.equal(SOURCE_SHA256, PIN.sha256);
});

// A class's [first, last] ranges, as the module spells them.
function parsed(spelled) {
    const out = [];
    const one = /\\u\{([0-9A-F]+)\}|_/y;
    let i = 0;
    const read = () => {
        one.lastIndex = i;
        const m = one.exec(spelled);
        assert.ok(m, `a code point at ${i}`);
        i = one.lastIndex;
        return m[0] === "_" ? 0x5f : parseInt(m[1], 16);
    };
    while (i < spelled.length) {
        const a = read();
        let b = a;
        if (spelled[i] === "-") {
            i++;
            b = read();
        }
        out.push([a, b]);
    }
    return out;
}

test("each class is ranges in order, apart, and outside the surrogates", () => {
    for (const [name, cls] of [["WORD", WORD], ["DIGIT", DIGIT]]) {
        const list = parsed(cls);
        assert.ok(list.length > 0, name);
        list.forEach(([a, b], k) => {
            assert.ok(a <= b && b <= 0x10ffff, `${name} ${a}-${b}`);
            assert.ok(b < 0xd800 || a > 0xdfff, `${name} ${a}-${b} misses the surrogates`);
            if (k > 0) {
                assert.ok(a > list[k - 1][1] + 1, `${name} ${a} comes after, apart from, the range before`);
            }
        });
    }
});

test("\\w is letters, marks, numbers and _, and \\d decimal digits, under the u flag", () => {
    const word = new RegExp(`^[${WORD}]$`, "u");
    const digit = new RegExp(`^[${DIGIT}]$`, "u");
    for (const c of ["a", "Z", "é", "Ж", "日", "́", "٣", "²", "Ⅻ", "_", "\u{1D400}", "\u{1C89}"]) {
        assert.ok(word.test(c), `${JSON.stringify(c)} is a word character`);
    }
    for (const c of ["-", " ", " ", "!", "€", "\u{1F600}", "​"]) {
        assert.ok(!word.test(c), `${JSON.stringify(c)} isn't`);
    }
    for (const c of ["0", "9", "٣", "५", "\u{1D7CE}"]) {
        assert.ok(digit.test(c), `${JSON.stringify(c)} is a digit`);
    }
    for (const c of ["²", "Ⅻ", "a", "½"]) {
        assert.ok(!digit.test(c), `${JSON.stringify(c)} isn't`);
    }
});

test("the generator takes only the pinned file, and reads its First and Last pairs as ranges", () => {
    assert.throws(() => module("0041;LATIN CAPITAL LETTER A;Lu;0;L;;;;;N;;;;0061;\n"), /SHA-256 is [0-9a-f]+, not Unicode 16\.0\.0's/);
    const cats = categories("0041;LATIN CAPITAL LETTER A;Lu;0;L;;;;;N;;;;0061;\n4E00;<CJK Ideograph, First>;Lo;0;L;;;;;N;;;;;\n4E05;<CJK Ideograph, Last>;Lo;0;L;;;;;N;;;;;\n");
    assert.equal(cats.get(0x41), "Lu");
    assert.equal(cats.get(0x4e03), "Lo");
    assert.equal(cats.get(0x4e06), undefined);
});
