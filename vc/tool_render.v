module vc

import json2
import os
import time

const ansi_reset = '\x1b[0m'
const ansi_dim = '\x1b[2m'
const thinking_frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']

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
	markdown        MarkdownStreamState
	spinner         ThinkingSpinner
}

struct ThinkingSpinner {
mut:
	active  bool
	visible bool
	frame   int
	last_ms i64
}

fn (mut spinner ThinkingSpinner) begin() {
	spinner.active = os.is_atty(1) > 0
	spinner.visible = false
	spinner.frame = 0
	spinner.last_ms = 0
	spinner.tick(time.now().unix_milli())
}

fn (mut spinner ThinkingSpinner) tick(now_ms i64) {
	if !spinner.active || (spinner.last_ms > 0 && now_ms - spinner.last_ms < 80) { return }
	print('\r\x1b[2K\x1b[34m${thinking_frames[spinner.frame % thinking_frames.len]}${ansi_reset} Thinking…')
	flush_stdout()
	spinner.visible = true
	spinner.frame++
	spinner.last_ms = now_ms
}

fn (mut spinner ThinkingSpinner) stop() {
	if spinner.visible {
		print('\r\x1b[2K')
		flush_stdout()
	}
	spinner.active = false
	spinner.visible = false
}

fn render_tool_call(name string, arguments string) string {
	detail := match name {
		'Shell' {
			args := json2.decode[ShellArguments](arguments) or { ShellArguments{} }
			'$ ' + args.command
		}
		'Read' {
			args := json2.decode[ReadArguments](arguments) or { ReadArguments{} }
			if args.start > 0 || args.end > 0 {
				'${args.path}:${if args.start > 0 {
					args.start
				} else {
					1
				}}-${if args.end > 0 {
					args.end
				} else {
					args.start + 2999
				}}'
			} else {
				args.path
			}
		}
		'Edit' {
			args := json2.decode[EditArguments](arguments) or { EditArguments{} }
			args.path
		}
		'WebSearch' {
			args := json2.decode[SearchArguments](arguments) or { SearchArguments{} }
			args.query
		}
		else {
			'invalid arguments'
		}
	}
	available := terminal_columns() - name.len - 2
	preview := single_line_preview(detail, available)
	if name == 'Shell' {
		return '\x1b[1;34m${name}${ansi_reset} ${highlight_shell(preview)}'
	}
	return '\x1b[1;34m${name}${ansi_reset} ${preview}'
}

fn highlight_shell(command string) string {
	tokens := shell_tokens(command)
	mut result := ''
	mut expect_command := false
	for token in tokens {
		if token.trim_space() == '' {
			result += token
			continue
		}
		if token == '$' && result == '' {
			result += token
			expect_command = true
		} else if is_shell_operator(token) {
			result += '\x1b[35m${token}${ansi_reset}'
			if token in ['|', '||', '&&', ';'] { expect_command = true }
		} else if token.starts_with("'") || token.starts_with('"') {
			result += '\x1b[33m${token}${ansi_reset}'
			expect_command = false
		} else if expect_command {
			result += '\x1b[36m${token}${ansi_reset}'
			expect_command = false
		} else if token.starts_with('-') || token.contains('$') {
			result += '\x1b[35m${token}${ansi_reset}'
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

fn render_failed_tool_call(name string, arguments string) string {
	plain := sanitize_terminal(render_tool_call(name, arguments))
	detail := plain.all_after(name).trim_space()
	return '\x1b[1;31m${name}${ansi_reset} ${detail} ${ansi_dim}· failed${ansi_reset}'
}

fn render_tool_result(name string, result string, arguments string) string {
	if error_message := tool_error_message(result) {
		return render_preview(error_message, 2048, 24)
	}
	return match name {
		'Shell' {
			value := json2.decode[ShellResult](result) or { return '' }
			render_preview(value.output, 2048, 24)
		}
		'Read' {
			''
		}
		'Edit' {
			render_edit_diff(arguments)
		}
		'WebSearch' {
			render_web_search_result(result)
		}
		else {
			''
		}
	}
}

fn tool_result_failed(name string, result string) bool {
	if _ := tool_error_message(result) { return true }
	if name == 'Shell' {
		value := json2.decode[ShellResult](result) or { return true }
		return value.exit_code != 0 || value.timed_out
	}
	return false
}

fn replace_visible_tool_call(rendered string, replacement string) {
	print(tool_result_collapse_sequence(rendered, terminal_columns()))
	println(replacement)
	flush_stdout()
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
		return '${ansi_dim}${result.len} bytes received${ansi_reset}'
	}
	mut lines := []string{}
	for item in decoded.web.results[..min_int(decoded.web.results.len, 5)] {
		lines << '• ${item.title}'
		lines << '  ${item.url}'
		if item.description != '' { lines << '  ${item.description}' }
	}
	content := if lines.len == 0 { 'No results.' } else { lines.join('\n') }
	return render_preview(content, 2048, 24)
}

fn render_edit_diff(arguments string) string {
	args := json2.decode[EditArguments](arguments) or { return '' }
	language := args.path.all_after_last('.').to_lower()
	mut lines := []string{}
	for line in args.old.split_into_lines() {
		lines << '\x1b[31m- ${ansi_reset}${highlight_code_line(line, language)}'
	}
	for line in args.replacement.split_into_lines() {
		lines << '\x1b[32m+ ${ansi_reset}${highlight_code_line(line, language)}'
	}
	return truncate_rendered_lines(lines, 2048, 24)
}

fn highlight_code_line(line string, language string) string {
	_ = language
	mut result := ''
	mut token := ''
	mut quote := u8(0)
	keywords := ['fn', 'struct', 'interface', 'enum', 'import', 'module', 'pub', 'mut', 'return',
		'if', 'else', 'for', 'match', 'const', 'type', 'class', 'def', 'func', 'var', 'let']
	for character in line.bytes() {
		if quote != 0 {
			token += character.ascii_str()
			if character == quote {
				result += '\x1b[33m${token}${ansi_reset}'
				token = ''
				quote = 0
			}
		} else if character in [`'`, `"`] {
			result += highlight_code_token(token, keywords)
			token = character.ascii_str()
			quote = character
		} else if character.is_alnum() || character == `_` {
			token += character.ascii_str()
		} else {
			result += highlight_code_token(token, keywords) + character.ascii_str()
			token = ''
		}
	}
	if quote != 0 {
		result += '\x1b[33m${token}${ansi_reset}'
	} else {
		result += highlight_code_token(token, keywords)
	}
	return result
}

fn highlight_code_token(token string, keywords []string) string {
	if token == '' { return '' }
	if token in keywords { return '\x1b[36m${token}${ansi_reset}' }
	if token.bytes().all(it.is_digit()) { return '\x1b[35m${token}${ansi_reset}' }
	return token
}

fn truncate_rendered_lines(lines []string, max_bytes int, max_lines int) string {
	mut shown := []string{}
	mut used := 0
	for line in lines {
		plain_len := sanitize_terminal(line).len
		if shown.len >= max_lines || used + plain_len > max_bytes { break
		 }
		shown << line
		used += plain_len + 1
	}
	if shown.len < lines.len {
		shown << '${ansi_dim}… ${lines.len - shown.len} diff lines hidden${ansi_reset}'
	}
	return shown.join('\n')
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
