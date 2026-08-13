module vc

import json2
import os
import time

pub struct JournalRecord {
pub:
	seq       u64
	kind      string
	data      string
	timestamp i64
}

pub struct Journal {
pub:
	path string
}

pub fn open_journal(path string) !Journal {
	os.mkdir_all(os.dir(path))!
	if !os.exists(path) {
		mut file := os.create(path)!
		file.close()
	}
	return Journal{
		path: path
	}
}

pub fn (journal Journal) append(seq u64, kind string, data string) ! {
	record := JournalRecord{
		seq:       seq
		kind:      kind
		data:      data
		timestamp: time.now().unix_milli()
	}
	mut file := os.open_append(journal.path)!
	defer { file.close() }
	file.writeln(json2.encode(record, escape_unicode: true))!
	file.flush()
}

pub fn (journal Journal) read_all() ![]JournalRecord {
	mut records := []JournalRecord{}
	for line in os.read_lines(journal.path)! {
		if line.trim_space() != '' {
			records << json2.decode[JournalRecord](line)!
		}
	}
	return records
}

// read_recent bounds replay memory while keeping complete records in the immutable journal.
// When reading from the middle of a file, the first partial JSONL record is discarded.
pub fn (journal Journal) read_recent(max_bytes int) ![]JournalRecord {
	if max_bytes <= 0 || !os.exists(journal.path) { return [] }
	size := os.file_size(journal.path)
	start := if size > u64(max_bytes) { size - u64(max_bytes) } else { u64(0) }
	mut file := os.open(journal.path)!
	defer { file.close() }
	file.seek(i64(start), .start)!
	mut buffer := []u8{len: int(size - start)}
	mut read := 0
	for read < buffer.len {
		count := file.read(mut buffer[read..]) or { break }
		if count <= 0 { break
		 }
		read += count
	}
	mut text := buffer[..read].bytestr()
	if start > 0 {
		newline := text.index('\n') or { return [] }
		text = text[newline + 1..]
	}
	mut records := []JournalRecord{}
	for line in text.split_into_lines() {
		if line.trim_space() == '' { continue
		 }
		records << json2.decode[JournalRecord](line) or { continue }
	}
	return records
}
