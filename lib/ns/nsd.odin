package ns

// nsd's protocol (upstream ADR-0009): namespace groups. Shared by nsd and
// lib/procns.
//
// A group's namespace is its namespace(6) text, as print writes it, and the
// connectors its mount lines name. nsd keeps both, and publishes the text in
// a VMO each member maps read-only: a sequence number, then the text. A
// member replays the text (as a spawned child replays its records) whenever
// the sequence has moved since it last did, before it resolves a name; so
// resolving takes no round trip. A member changes the namespace by doing the
// bind, mount or unmount on its own copy, then sending nsd the text it now
// prints, and the sequence it started from: nsd takes it only if no one else
// changed the group meanwhile (stale otherwise: the member catches up and
// does it again).
//
// Each member has its own channel to nsd, which says which group it is in.
// The first member makes the group (.New, on nsd's post); a member gets a
// channel for a child that shares its group with .Share.

import "abi:vx"

Nsd_Call :: enum u32 {
	// On nsd's post: a new group, from a namespace's text and its connectors
	// (handles, named in order by the "SRC\n" lines after the text). The reply
	// carries the caller's member channel and the group's VMO.
	New       = 1,
	// On a member channel: a channel for another member of the same group, to
	// give a child. The reply carries it.
	Share,
	// On a member channel, a new member saying who it is (args.task: its task
	// id): the reply carries the group's VMO.
	Hello,
	// On a member channel: the namespace's new text, from sequence args.seq,
	// and any new connectors, named as for New. Stale if the group has moved
	// on.
	Update,
	// On a member channel: the connector for the source named (the bytes
	// after the args). The reply carries a duplicate.
	Connector,
	// On nsd's post: the namespace text of the group task args.task is in,
	// for /proc/N/ns (procfs). Err_Not_Found if it is in none.
	Text,
}

Nsd_Args :: struct {
	seq:      u64, // .Update: the sequence the text was made from; a reply: the group's now
	task:     u64, // .New, .Hello: the caller's task id; .Text: the one asked about
	text_len: u32, // the bytes after the args that are text (.Connector: the source's name)
	count:    u32, // .New, .Update: connectors given, each named by a "SRC\n" line after the text
}

// A message: the header (its ordinal a Nsd_Call), the args, then bytes (text,
// names). A reply's header.flags is 0 or a vx.Status (stale is
// Err_Bad_State); .Text's carries the text after the args.
Nsd_Msg :: struct {
	header: vx.Msg_Header,
	args:   Nsd_Args,
}

#assert(size_of(Nsd_Args) == 24)
#assert(size_of(Nsd_Msg) == 40)

NSD_TEXT_MAX :: 16 * 1024 // a group's namespace text, at most

// The VMO a group's members map: seq, odd while nsd writes, then the text.
Nsd_Page :: struct {
	seq:      u64, // read and written atomically
	len:      u32,
	reserved: u32,
	text:     [NSD_TEXT_MAX]u8,
}

#assert(offset_of(Nsd_Page, text) == 16)
