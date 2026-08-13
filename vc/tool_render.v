module vc

import json2
import os

const ansi_reset = '\x1b[0m'
const ansi_dim = '\x1b[2m'
const ansi_bold = '\x1b[1m'

struct BraveSearchResponse {
	web BraveWebResults
}

struct BraveWebResults {
	results []BraveSearchResult
}

struct BraveSearchResult {
	title       string
	url         string
	description string
}

struct ToolDisplayState {
mut:
	expanded_result string
}

fn render_tool_call(name string, arguments string) string {
	if name == 'Shell' {
		args := json2.decode[ShellArguments](arguments) or { ShellArguments{} }
		mut rendered := '${tool_style(name)}▶ Shell${ansi_reset}\n${ansi_dim}│${ansi_reset} $ ${highlight_shell(args.command)}'
		if args.timeout_ms > 0 {
			rendered += '\n${ansi_dim}└ timeout ${format_timeout(args.timeout_ms)}${ansi_reset}'
		} else {
			rendered += '\n${ansi_dim}└${ansi_reset}'
		}
		return rendered
	}
	detail := match name {
		'Read' {
			args := json2.decode[ReadArguments](arguments) or { ReadArguments{} }
			args.path
		}
		'Edit' {
			args := json2.decode[EditArguments](arguments) or { EditArguments{} }
			'${args.path} · exact replacement'
		}
		'WebSearch' {
			args := json2.decode[SearchArguments](arguments) or { SearchArguments{} }
			args.query
		}
		else {
			'invalid arguments'
		}
	}
	return '${tool_style(name)}▶ ${name}${ansi_reset}\n${ansi_dim}│${ansi_reset} ${single_line_preview(detail,
		512)}\n${ansi_dim}└${ansi_reset}'
}

fn highlight_shell(command string) string {
	tokens := shell_tokens(sanitize_terminal(command).replace('\n', ' '))
	mut result := ''
	mut expect_command := true
	for token in tokens {
		if token.trim_space() == '' {
			result += token
			continue
		}
		if is_shell_operator(token) {
			result += '\x1b[31m${token}${ansi_reset}'
			if token in ['|', '||', '&&', ';'] { expect_command = true }
		} else if token.starts_with("'") || token.starts_with('"') {
			result += '\x1b[35m${token}${ansi_reset}'
			expect_command = false
		} else if expect_command {
			result += '\x1b[1;32m${token}${ansi_reset}'
			expect_command = false
		} else if token.starts_with('-') {
			result += '\x1b[33m${token}${ansi_reset}'
		} else if token.contains('$') {
			result += '\x1b[36m${token}${ansi_reset}'
		} else {
			result += token
		}
	}
	return result
}

fn shell_tokens(command string) []string {
	mut tokens := []string{}
	mut current := ''
	mut quote := u8(0)
	mut index := 0
	for index < command.len {
		character := command[index]
		if quote != 0 {
			current += character.ascii_str()
			if character == quote && (index == 0 || command[index - 1] != `\\`) {
				tokens << current
				current = ''
				quote = 0
			}
			index++
			continue
		}
		if character in [`'`, `"`] {
			if current != '' { tokens << current }
			current = character.ascii_str()
			quote = character
			index++
			continue
		}
		if character in [` `, `\t`] {
			if current != '' {
				tokens << current
				current = ''
			}
			tokens << character.ascii_str()
			index++
			continue
		}
		if character in [`|`, `&`, `;`, `<`, `>`] {
			if current != '' {
				tokens << current
				current = ''
			}
			mut operator := character.ascii_str()
			if index + 1 < command.len && command[index + 1] == character {
				operator += character.ascii_str()
				index++
			}
			tokens << operator
			index++
			continue
		}
		current += character.ascii_str()
		index++
	}
	if current != '' { tokens << current }
	return tokens
}

fn is_shell_operator(value string) bool {
	return value in ['|', '||', '&', '&&', ';', '<', '>', '<<', '>>']
}

fn format_timeout(milliseconds int) string {
	if milliseconds % 1000 == 0 { return '${milliseconds / 1000}s' }
	return '${milliseconds}ms'
}

fn render_tool_result(name string, result string) string {
	if error_message := tool_error_message(result) {
		return '\x1b[1;31m◀ ${name} error${ansi_reset}\n${render_preview(error_message, 2048, 24)}'
	}
	return match name {
		'Shell' {
			value := json2.decode[ShellResult](result) or {
				return '\x1b[1;31m◀ Shell invalid result${ansi_reset}'
			}
			color := if value.exit_code == 0 && !value.timed_out {
				'\x1b[1;32m'
			} else {
				'\x1b[1;31m'
			}
			status := if value.timed_out { 'timed out' } else { 'exit ${value.exit_code}' }
			'${color}◀ Shell · ${status}${ansi_reset}\n${render_preview(value.output, 2048, 24)}'
		}
		'Read' {
			value := json2.decode[ReadResult](result) or {
				return '\x1b[1;31m◀ Read invalid result${ansi_reset}'
			}
			fingerprint := if value.fingerprint.len > 12 {
				value.fingerprint[..12]
			} else {
				value.fingerprint
			}
			'${tool_style(name)}◀ Read · ${value.path} · ${fingerprint}${ansi_reset}'
		}
		'Edit' {
			fingerprint := json_field(result, 'fingerprint')
			'${tool_style(name)}◀ Edit · saved · ${single_line_preview(fingerprint, 16)}${ansi_reset}'
		}
		'WebSearch' {
			render_web_search_result(result)
		}
		else {
			'${tool_style(name)}◀ ${name} · complete${ansi_reset}'
		}
	}
}

fn collapse_visible_tool_result(rendered string) {
	if rendered == '' { return }
	print(tool_result_collapse_sequence(rendered, terminal_columns()))
	flush_stdout()
}

fn tool_result_collapse_sequence(rendered string, columns int) string {
	width := if columns >= 20 { columns } else { 80 }
	mut rows := 0
	for line in sanitize_terminal(rendered).split_into_lines() {
		characters := line.runes().len
		rows += if characters == 0 { 1 } else { (characters + width - 1) / width }
	}
	if rows == 0 { return '' }
	return '\x1b[${rows}A\r\x1b[J'
}

fn terminal_columns() int {
	configured := os.getenv('COLUMNS').int()
	return if configured >= 20 { configured } else { 80 }
}

fn render_web_search_result(result string) string {
	decoded := json2.decode[BraveSearchResponse](result) or {
		return '${tool_style('WebSearch')}◀ WebSearch · ${result.len} bytes received${ansi_reset}'
	}
	mut lines := []string{}
	for item in decoded.web.results[..min_int(decoded.web.results.len, 5)] {
		lines << '• ${item.title}'
		lines << '  ${item.url}'
		if item.description != '' { lines << '  ${item.description}' }
	}
	content := if lines.len == 0 { 'No results.' } else { lines.join('\n') }
	return '${tool_style('WebSearch')}◀ WebSearch · ${decoded.web.results.len} results${ansi_reset}\n${render_preview(content,
		2048, 24)}'
}

fn render_preview(value string, max_bytes int, max_lines int) string {
	clean := sanitize_terminal(value).replace('\r', '')
	lines := clean.split_into_lines()
	mut shown := []string{}
	mut used := 0
	for line in lines {
		if shown.len >= max_lines || used >= max_bytes { break
		 }
		remaining := max_bytes - used
		piece := safe_text_prefix(line, remaining)
		shown << '${ansi_dim}│${ansi_reset} ${piece}'
		used += piece.len + 1
		if piece.len < line.len { break
		 }
	}
	if shown.len == 0 { shown << '${ansi_dim}│ (no output)${ansi_reset}' }
	hidden_bytes := if clean.len > used { clean.len - used } else { 0 }
	hidden_lines := if lines.len > shown.len { lines.len - shown.len } else { 0 }
	if hidden_bytes > 0 || hidden_lines > 0 {
		shown << '${ansi_dim}└ … ${hidden_bytes} bytes / ${hidden_lines} lines hidden${ansi_reset}'
	} else {
		shown << '${ansi_dim}└${ansi_reset}'
	}
	return shown.join('\n')
}

fn safe_text_prefix(value string, max_bytes int) string {
	if max_bytes <= 0 { return '' }
	if value.len <= max_bytes { return value }
	mut result := ''
	for character in value.runes() {
		piece := character.str()
		if result.len + piece.len > max_bytes { break
		 }
		result += piece
	}
	return result
}

fn single_line_preview(value string, max_bytes int) string {
	return safe_text_prefix(sanitize_terminal(value).replace('\n', ' ').replace('\r', ' '),
		max_bytes)
}

fn tool_error_message(result string) ?string {
	if !result.contains('"error"') { return none }
	message := json_field(result, 'error')
	if message == '' { return none }
	return message
}

fn tool_style(name string) string {
	color := match name {
		'Shell' { '33' }
		'Read' { '36' }
		'Edit' { '35' }
		'WebSearch' { '34' }
		else { '37' }
	}
	return '\x1b[${color}m${ansi_bold}'
}
