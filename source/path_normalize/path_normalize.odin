package path_normalize

import utf8 "core:unicode/utf8"

// path_nfc converts a name into its canonical Unicode NFC form. Directory
// entries created on macOS are often stored NFD while Linux holds NFC, so the
// same track can spell its path differently per machine. music.rms blob keys,
// TRACKS lookups and the saved settings maps all route through path_nfc so
// one spelling is used everywhere; file opens keep the raw readdir bytes.
//
// The tables in path_normalize_tables.odin plus Hangul arithmetic cover every
// canonical decomposition. Inputs are assumed canonically ordered (NFC or NFD
// files); on such inputs the result is exactly NFC, and on any input it is
// idempotent, so blob and runtime keys always agree.
Runes :: [dynamic; 1024]rune

@(private = "file")
CHO_BASE :: 0x1100

@(private = "file")
JUNG_BASE :: 0x1161

@(private = "file")
JONG_BASE :: 0x11A7

@(private = "file")
SYLLABLE_BASE :: 0xAC00

@(private = "file")
JUNG_COUNT :: 21

@(private = "file")
JONG_COUNT :: 28

@(private = "file")
is_cho :: proc(cp: u32) -> bool {
	return cp >= CHO_BASE && cp <= CHO_BASE + 18
}

@(private = "file")
is_jung :: proc(cp: u32) -> bool {
	return cp >= JUNG_BASE && cp <= JUNG_BASE + 20
}

@(private = "file")
is_jong :: proc(cp: u32) -> bool {
	return cp >= JONG_BASE && cp <= JONG_BASE + 27
}

@(private = "file")
is_syllable :: proc(cp: u32) -> bool {
	return cp >= SYLLABLE_BASE && cp <= 0xD7A3
}

@(private = "file")
nfc_decompose :: proc(cp: u32) -> (base, mark: u32, ok: bool) {
	lo := 0
	hi := int(len(Nfc_Decomp_Src)) - 1
	for lo <= hi {
		mid := lo + (hi - lo) / 2
		value := Nfc_Decomp_Src[mid]
		if value < cp {
			lo = mid + 1
		} else if value > cp {
			hi = mid - 1
		} else {
			pair := Nfc_Decomp_Pairs[mid]
			return pair.base, pair.mark, true
		}
	}
	return 0, 0, false
}

@(private = "file")
nfc_compose :: proc(base, mark: u32) -> (composed: u32, ok: bool) {
	lo := 0
	hi := int(len(Nfc_Comp_Pairs)) - 1
	for lo <= hi {
		mid := lo + (hi - lo) / 2
		pair := Nfc_Comp_Pairs[mid]
		if pair.base < base || (pair.base == base && pair.mark < mark) {
			lo = mid + 1
		} else if pair.base > base || (pair.base == base && pair.mark > mark) {
			hi = mid - 1
		} else {
			return Nfc_Comp_Composed[mid], true
		}
	}
	return 0, false
}

@(private = "file")
nfc_mark_class :: proc(cp: u32) -> u8 {
	lo := 0
	hi := int(len(Nfc_Mark_Classes)) - 1
	for lo <= hi {
		mid := lo + (hi - lo) / 2
		value := Nfc_Mark_Classes[mid]
		if value.cp < cp {
			lo = mid + 1
		} else if value.cp > cp {
			hi = mid - 1
		} else {
			return value.class
		}
	}
	return 0
}

path_nfc :: proc(name: string) -> string {
	// Plain ASCII is already canonical and is the common case.
	ascii := true
	for byte in name {
		if byte >= 0x80 {
			ascii = false
			break
		}
	}
	if ascii do return name

	// Pass 1: canonical decomposition.
	runes: Runes
	s := name
	for len(s) > 0 {
		r, w := utf8.decode_rune_in_string(s)
		cp := u32(r)
		if is_syllable(cp) {
			v := cp - SYLLABLE_BASE
			append(&runes, rune(CHO_BASE + v / (JUNG_COUNT * JONG_COUNT)))
			append(&runes, rune(JUNG_BASE + (v % (JUNG_COUNT * JONG_COUNT)) / JONG_COUNT))
			if v % JONG_COUNT > 0 do append(&runes, rune(JONG_BASE + v % JONG_COUNT))
		} else if base, mark, ok := nfc_decompose(cp); ok {
			append(&runes, rune(base))
			if mark > 0 do append(&runes, rune(mark))
		} else {
			append(&runes, r)
		}
		s = s[w:]
	}
	ensure(len(runes) <= cap(Runes), "Path too long to normalize; bump Runes capacity")

	// Pass 2: composition, in place. A mark composes with the last base unless
	// a combining character of equal or higher class already follows it.
	write := 0
	base_index := -1
	for i in 0 ..< len(runes) {
		r := runes[i]
		cp := u32(r)
		cl := nfc_mark_class(cp)
		if cl > 0 {
			prev_class: u8
			if write > 0 do prev_class = nfc_mark_class(u32(runes[write - 1]))
			if write > 0 && (prev_class == 0 || prev_class < cl) {
				composed, ok := nfc_compose(u32(runes[base_index]), cp)
				if ok {
					runes[base_index] = rune(composed)
					continue
				}
			}
			runes[write] = r
			write += 1
		} else if is_jong(cp) && base_index >= 0 && base_index == write - 1 {
			syllable := u32(runes[base_index])
			if is_syllable(syllable) && (syllable - SYLLABLE_BASE) % JONG_COUNT == 0 {
				runes[base_index] = rune(syllable + cp - JONG_BASE)
				continue
			}
			runes[write] = r
			write += 1
			base_index = write - 1
		} else if is_jung(cp) && base_index >= 0 && base_index == write - 1 {
			cho := u32(runes[base_index])
			if is_cho(cho) {
				runes[base_index] = rune(
					SYLLABLE_BASE + (cho - CHO_BASE) * JUNG_COUNT * JONG_COUNT + (cp - JUNG_BASE) * JONG_COUNT,
				)
				continue
			}
			runes[write] = r
			write += 1
			base_index = write - 1
		} else {
			runes[write] = r
			write += 1
			base_index = write - 1
		}
	}

	return utf8.runes_to_string(runes[:write], context.temp_allocator)
}
