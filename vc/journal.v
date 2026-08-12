module vc

import json
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
	file.writeln(json.encode(record))!
	file.flush()
}

pub fn (journal Journal) read_all() ![]JournalRecord {
	mut records := []JournalRecord{}
	for line in os.read_lines(journal.path)! {
		if line.trim_space() != '' {
			records << json.decode(JournalRecord, line)!
		}
	}
	return records
}
