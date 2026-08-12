module vc

import time

pub struct Event {
pub:
	seq     u64
	kind    string
	data    string
	time_ms i64
}

pub struct EventRing {
pub:
	capacity int
pub mut:
	items    []Event
	next_seq u64 = 1
}

pub fn new_event_ring(capacity int) EventRing {
	return EventRing{
		capacity: if capacity > 0 { capacity } else { 1 }
	}
}

pub fn (mut ring EventRing) push(kind string, data string) Event {
	event := Event{
		seq:     ring.next_seq
		kind:    kind
		data:    data
		time_ms: time.now().unix_milli()
	}
	ring.next_seq++
	if ring.items.len == ring.capacity {
		ring.items.delete(0)
	}
	ring.items << event
	return event
}

pub fn (ring &EventRing) after(cursor u64) []Event {
	return ring.items.filter(it.seq > cursor)
}
