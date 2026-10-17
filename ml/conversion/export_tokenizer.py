"""Export the CLIP BPE vocabulary for the Swift tokenizer and generate golden test vectors.

Writes build/tokenizer/{vocab.json,merges.txt} (bundle these in the app; derived from open_clip's
bpe_simple_vocab_16e6.txt.gz, the OpenAI CLIP vocabulary) and golden_tokens.json (small, committed
so Swift unit tests can check the port). Also checks a plain-Python reimplementation of the exact
algorithm Swift must follow against open_clip's tokenizer, so the Swift port has a verified spec.
"""
import gzip, json, os, re
import open_clip
from open_clip import tokenizer as T

PHRASES = ["a cat", "a photo of a cat", "the blue backpack by the door", "A Red   Mug!", "keys",
           "it's a café table", "TV remote", "50 cm chair", "", "a " + "very long phrase " * 30]


def bytes_to_unicode():
    bs = list(range(ord("!"), ord("~") + 1)) + list(range(ord("¡"), ord("¬") + 1)) + list(range(ord("®"), ord("ÿ") + 1))
    cs, n = bs[:], 0
    for b in range(256):
        if b not in bs:
            bs.append(b); cs.append(256 + n); n += 1
    return dict(zip(bs, map(chr, cs)))


def build():
    path = os.path.join(os.path.dirname(open_clip.__file__), "bpe_simple_vocab_16e6.txt.gz")
    merges = gzip.open(path).read().decode("utf-8").split("\n")[1 : 49152 - 256 - 2 + 1]
    merges = [tuple(m.split()) for m in merges]
    b2u = bytes_to_unicode()
    vocab = list(b2u.values()); vocab += [v + "</w>" for v in vocab]
    vocab += ["".join(m) for m in merges]; vocab += ["<start_of_text>", "<end_of_text>"]
    return merges, {t: i for i, t in enumerate(vocab)}, b2u


MERGES, ENC, B2U = build()
RANK = {m: i for i, m in enumerate(MERGES)}
PAT = re.compile(r"<start_of_text>|<end_of_text>|'s|'t|'re|'ve|'m|'ll|'d|[^\W\d_]+|\d|(?:[^\s\w]|_)+", re.IGNORECASE)  # = open_clip's \p{L}+|\p{N}|[^\s\p{L}\p{N}]+ (single digits!)


def bpe(token):
    word = tuple(token[:-1]) + (token[-1] + "</w>",)
    while len(word) > 1:
        pairs = {(a, b) for a, b in zip(word, word[1:])}
        best = min(pairs, key=lambda p: RANK.get(p, 1e18))
        if best not in RANK:
            break
        out, i = [], 0
        while i < len(word):
            if i < len(word) - 1 and (word[i], word[i + 1]) == best:
                out.append(word[i] + word[i + 1]); i += 2
            else:
                out.append(word[i]); i += 1
        word = tuple(out)
    return word


def encode(text, ctx=77):
    text = re.sub(r"\s+", " ", text).strip().lower()   # whitespace_clean + lower (ftfy/html.unescape skipped)
    ids = []
    for tok in re.findall(PAT, text):
        tok = "".join(B2U[b] for b in tok.encode("utf-8"))
        ids += [ENC[p] for p in bpe(tok)]
    ids = [49406] + ids[: ctx - 2] + [49407]
    return ids + [0] * (ctx - len(ids))


def main():
    os.makedirs("build/tokenizer", exist_ok=True)
    json.dump(ENC, open("build/tokenizer/vocab.json", "w"), ensure_ascii=False)
    open("build/tokenizer/merges.txt", "w").write("\n".join(" ".join(m) for m in MERGES) + "\n")
    tk = open_clip.get_tokenizer("ViT-B-16")
    golden, bad = [], 0
    for p in PHRASES:
        ref = tk([p])[0].tolist(); mine = encode(p)
        bad += ref != mine
        golden.append({"text": p, "ids": ref})
    json.dump(golden, open("golden_tokens.json", "w"), indent=0)
    print(f"vocab={len(ENC)} merges={len(MERGES)} golden={len(golden)} mismatches_vs_open_clip={bad}")
    return bad


if __name__ == "__main__":
    raise SystemExit(main())
