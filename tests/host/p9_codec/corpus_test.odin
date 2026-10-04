// Upstream's p9_decode fuzzer (tests/fuzz/p9_decode_fuzz.c) over its corpus
// (tests/fuzz/corpus/p9_decode), each whole file and each message in it,
// and every truncation of those: whatever decodes, as a message or a stat
// entry, must encode back to exactly the same bytes, so the decoder can
// neither crash nor accept something it would not have written.
package p9_codec_test

import "core:testing"
import "vx:p9"

CORPUS := #load_directory("corpus")

@(private="file")
p9_decode_fuzz :: proc(t: ^testing.T, name: string, data: []u8) {
	again: [1 << 16]u8
	m: p9.Msg
	if p9.decode(data, &m) == .Ok {
		n := p9.encode(&m, again[:])
		testing.expectf(t, string(again[:n]) == string(data), "%s: a %v does not encode back", name, m.type)
	}
	s: p9.Stat
	if p9.stat_decode(data, &s) == .Ok {
		n := p9.stat_encode(&s, again[:])
		testing.expectf(t, string(again[:n]) == string(data), "%s: a stat entry does not encode back", name)
	}
	_, _ = p9.version_parse(string(data))
}

@(test)
test_corpus :: proc(t: ^testing.T) {
	testing.expect_value(t, len(CORPUS), 1)
	decoded := 0
	for file in CORPUS {
		data := file.data
		for cut in 0 ..= len(data) {
			p9_decode_fuzz(t, file.name, data[:cut])
		}
		// The file is a session: each of its messages, framed by its size[4].
		for pos := 0; len(data) - pos >= 4; {
			n := int(data[pos]) | int(data[pos + 1]) << 8 | int(data[pos + 2]) << 16 | int(data[pos + 3]) << 24
			if n < 4 || n > len(data) - pos {
				break
			}
			m: p9.Msg
			if p9.decode(data[pos:][:n], &m) == .Ok {
				decoded += 1
			}
			p9_decode_fuzz(t, file.name, data[pos:][:n])
			pos += n
		}
	}
	testing.expect(t, decoded > 0)
}
