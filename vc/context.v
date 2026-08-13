module vc

import crypto.sha256
import json2
import os
import time

pub struct ContextItem {
pub:
	seq     u64
	kind    string
	content string
	tokens  int
}

pub struct SummaryCheckpoint {
pub:
	start_seq      u64
	end_seq        u64
	input_hash     string
	policy_version string
	model          string
	result         string
	created_ms     i64
}

pub interface SmallModel {
	complete(system string, prompt string, max_tokens int) !string
}

pub struct ContextProjection {
pub:
	items      []ContextItem
	checkpoint ?SummaryCheckpoint
}

pub fn project_context(transcript []ContextItem, context_limit int, small_model string, summarizer SmallModel) !ContextProjection {
	if transcript.len == 0 { return ContextProjection{} }
	mut items := transcript.clone()
	mut used := count_tokens(items)
	if used * 100 >= context_limit * 65 {
		cutoff := items.len * 2 / 3
		mut without_old_reasoning := []ContextItem{cap: items.len}
		for index, item in items {
			if index >= cutoff || item.kind != 'reasoning' { without_old_reasoning << item }
		}
		items = without_old_reasoning.clone()
		used = count_tokens(items)
	}
	if used * 100 >= context_limit * 75 {
		items = abridge_tools(items)
		used = count_tokens(items)
	}
	if used * 100 >= context_limit * 85 && items.len > 2 {
		cutoff := items.len * 2 / 3
		old := items[..cutoff].clone()
		input := old.map('${it.kind}: ${it.content}').join('\n')
		summary := summarizer.complete('Summarize the coding-agent transcript. Preserve decisions, failures, files, and unfinished work.',
			input, min_int(context_limit / 10, 2048))!
		checkpoint := SummaryCheckpoint{
			start_seq:      old[0].seq
			end_seq:        old#[-1..][0].seq
			input_hash:     sha256.hexhash(input)
			policy_version: 'v1'
			model:          small_model
			result:         summary
			created_ms:     time.now().unix_milli()
		}
		mut compacted := [
			ContextItem{
				seq:     old[0].seq
				kind:    'summary'
				content: summary
				tokens:  estimate_tokens(summary)
			},
		]
		compacted << items[cutoff..]
		return ContextProjection{
			items:      compacted
			checkpoint: checkpoint
		}
	}
	return ContextProjection{
		items: items
	}
}

pub fn journal_checkpoint(journal Journal, checkpoint SummaryCheckpoint, seq u64) ! {
	journal.append(seq, 'summary_checkpoint', json2.encode(checkpoint, escape_unicode: true))!
}

pub fn build_session_prompt(session_id string, instructions string, skill string, current_message string, cfg Config) !string {
	journal := open_journal(os.join_path(session_dir(session_id), 'transcript.jsonl'))!
	records := journal.read_recent(4 * 1024 * 1024)!
	mut items := []ContextItem{}
	mut removed_current := false
	for index, record in records {
		if record.kind == 'summary_checkpoint' { continue
		 }
		if !removed_current && index == records.len - 1 && record.kind == 'user'
			&& record.data == current_message {
			removed_current = true
			continue
		}
		if record.kind !in ['user', 'assistant', 'system', 'tool_call', 'tool_result', 'summary',
			'abridged_tools'] {
			continue
		}
		items << ContextItem{
			seq:     u64(index + 1)
			kind:    record.kind
			content: record.data
			tokens:  estimate_tokens(record.data)
		}
	}
	projection := project_context(items, 128_000, cfg.small_model, ProviderSmallModel{
		model:  cfg.small_model
		config: cfg
	}) or {
		ContextProjection{
			items: bounded_context_tail(items, 100_000)
		}
	}
	mut prompt := instructions
	if skill != '' { prompt += '\n\nThe user explicitly activated this skill:\n' + skill }
	if projection.items.len > 0 {
		prompt += '\n\nPrevious session history:\n'
		for item in projection.items {
			prompt += '\n[${context_kind_label(item.kind)}]\n${item.content}\n'
		}
	}
	prompt += '\n\nCurrent user request:\n' + current_message
	return prompt
}

fn bounded_context_tail(items []ContextItem, token_limit int) []ContextItem {
	mut result := []ContextItem{}
	mut used := 0
	for index := items.len - 1; index >= 0; index-- {
		item := items[index]
		tokens := if item.tokens > 0 { item.tokens } else { estimate_tokens(item.content) }
		if used + tokens > token_limit { break
		 }
		result.prepend(item)
		used += tokens
	}
	return result
}

fn context_kind_label(kind string) string {
	return match kind {
		'user' { 'User' }
		'assistant' { 'Assistant' }
		'system' { 'System' }
		'tool_call' { 'Tool call' }
		'tool_result' { 'Tool result' }
		'summary' { 'Earlier history summary' }
		'abridged_tools' { 'Earlier tool activity' }
		else { kind }
	}
}

pub fn session_recap_source(session_id string) !string {
	journal := open_journal(os.join_path(session_dir(session_id), 'transcript.jsonl'))!
	records := journal.read_recent(64 * 1024)!
	mut lines := []string{}
	for record in records {
		if record.kind in ['user', 'assistant', 'system', 'tool_call', 'tool_result'] {
			lines << '${context_kind_label(record.kind)}: ${record.data}'
		}
	}
	return lines.join('\n')
}

fn abridge_tools(items []ContextItem) []ContextItem {
	mut result := []ContextItem{}
	mut tool_lines := []string{}
	mut first_seq := u64(0)
	for item in items {
		if item.kind in ['tool_call', 'tool_result'] {
			if tool_lines.len == 0 { first_seq = item.seq }
			tool_lines << '${item.kind}: ${bounded_text(item.content, 256)}'
			continue
		}
		if tool_lines.len > 0 {
			content := bounded_text(tool_lines.join('\n'), 1024)
			result << ContextItem{
				seq:     first_seq
				kind:    'abridged_tools'
				content: content
				tokens:  estimate_tokens(content)
			}
			tool_lines.clear()
		}
		result << item
	}
	if tool_lines.len > 0 {
		content := bounded_text(tool_lines.join('\n'), 1024)
		result << ContextItem{
			seq:     first_seq
			kind:    'abridged_tools'
			content: content
			tokens:  estimate_tokens(content)
		}
	}
	return result
}

fn count_tokens(items []ContextItem) int {
	mut total := 0
	for item in items {
		total += if item.tokens > 0 { item.tokens } else { estimate_tokens(item.content) }
	}
	return total
}

fn estimate_tokens(text string) int {
	return (text.len + 3) / 4
}

fn bounded_text(text string, limit int) string {
	if text.len <= limit { return text }
	return text[..limit] + '…'
}

fn min_int(a int, b int) int {
	return if a < b { a } else { b }
}
