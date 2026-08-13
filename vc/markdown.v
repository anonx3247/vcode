module vc

pub struct MarkdownRenderer {
pub mut:
	cache map[string][]string
}

struct MarkdownStreamState {
mut:
	renderer MarkdownRenderer
	source   string
	rendered string
	id       u64
}

fn (mut state MarkdownStreamState) begin() {
	state.id++
	state.source = ''
	state.rendered = ''
}

fn (mut state MarkdownStreamState) push(delta string, width int) string {
	state.source += delta
	message_id := 'stream-${state.id}'
	state.renderer.invalidate(message_id)
	next := state.renderer.render(message_id, state.source, width).join('\n')
	mut output := ''
	if state.rendered != '' {
		output += tool_result_collapse_sequence(state.rendered, width)
	}
	output += next + '\n'
	state.rendered = next
	return output
}

pub fn (mut renderer MarkdownRenderer) render(message_id string, source string, width int) []string {
	key := '${message_id}:${width}:${source.len}:${simple_hash(source)}'
	if cached := renderer.cache[key] { return cached.clone() }
	clean := sanitize_terminal(source)
	mut lines := []string{}
	mut in_fence := false
	mut language := ''
	mut fence := []string{}
	for line in clean.split_into_lines() {
		if line.starts_with('```') {
			if in_fence {
				lines << render_fence(language, fence, width)
				fence.clear()
				in_fence = false
				language = ''
			} else {
				in_fence = true
				language = line[3..].trim_space()
			}
			continue
		}
		if in_fence {
			fence << line
			continue
		}
		lines << render_markdown_line(line, width)
	}
	if in_fence {
		lines << '```' + language
		for line in fence {
			lines << wrap_line(line, width, '│ ')
		}
	}
	renderer.cache[key] = lines.clone()
	return lines
}

pub fn (mut renderer MarkdownRenderer) invalidate(message_id string) {
	for key in renderer.cache.keys() {
		if key.starts_with('${message_id}:') { renderer.cache.delete(key) }
	}
}

fn render_markdown_line(line string, width int) []string {
	if line.starts_with('# ') || line.starts_with('## ') || line.starts_with('### ')
		|| line.starts_with('#### ') || line.starts_with('##### ') || line.starts_with('###### ') {
		return wrap_line(line.trim_left('#').trim_space().to_upper(), width, '').map('\x1b[1;36m${it}${ansi_reset}')
	}
	if line.starts_with('> ') {
		return wrap_line(line[2..], width, '│ ').map('${ansi_dim}${render_inline(it)}${ansi_reset}')
	}
	if line.starts_with('- ') || line.starts_with('* ') {
		return wrap_line(line[2..], width, '• ').map(render_inline(it))
	}
	if line.len >= 3 && line.trim(' -_*') == '' {
		return ['${ansi_dim}${'─'.repeat(min_int(width, 40))}${ansi_reset}']
	}
	if line.contains('|') && line.trim_space().starts_with('|') {
		return render_table_row(line, width)
	}
	return wrap_line(line, width, '').map(render_inline(it))
}

fn render_inline(line string) string {
	mut result := ''
	mut index := 0
	mut bold := false
	mut italic := false
	mut code := false
	for index < line.len {
		if line[index] == `[` && !code {
			close_text := line[index + 1..].index('](') or { -1 }
			if close_text >= 0 {
				url_start := index + 1 + close_text + 2
				url_end_offset := line[url_start..].index(')') or { -1 }
				if url_end_offset >= 0 {
					label := line[index + 1..index + 1 + close_text]
					url := line[url_start..url_start + url_end_offset]
					result += '\x1b[4;34m${label}${ansi_reset}${ansi_dim} (${url})${ansi_reset}'
					index = url_start + url_end_offset + 1
					continue
				}
			}
		}
		if line[index] == `\`` {
			code = !code
			result += if code { '\x1b[36m' } else { ansi_reset }
			index++
			continue
		}
		if !code && index + 1 < line.len && line[index..index + 2] in ['**', '__'] {
			bold = !bold
			result += if bold { '\x1b[1m' } else { ansi_reset }
			index += 2
			continue
		}
		if !code && line[index] in [`*`, `_`] {
			marker := line[index].ascii_str()
			if italic || line[index + 1..].contains(marker) {
				italic = !italic
				result += if italic { '\x1b[3m' } else { ansi_reset }
				index++
				continue
			}
		}
		result += line[index].ascii_str()
		index++
	}
	if bold || italic || code { result += ansi_reset }
	return result
}

fn render_table_row(line string, width int) []string {
	cells := line.trim(' |').split('|').map(it.trim_space())
	if cells.len == 0 { return [] }
	cell_width := if width / cells.len > 4 { width / cells.len - 3 } else { 4 }
	mut clipped := []string{}
	for cell in cells {
		clipped << bounded_text(cell, cell_width)
	}
	return [
		'\x1b[36m│${ansi_reset} ' +
			clipped.map(render_inline(it)).join(' \x1b[36m│${ansi_reset} ') +
			' \x1b[36m│${ansi_reset}',
	]
}

fn render_fence(language string, source []string, width int) []string {
	if language.to_lower() in ['mermaid', 'mmd'] {
		if diagram := render_mermaid(source, width) { return diagram }
	}
	mut lines := [
		'${ansi_dim}┌─ ${if language == '' { 'code' } else { language }}${ansi_reset}',
	]
	for line in source {
		for wrapped in wrap_line(line, width - 2, '') {
			lines << '${ansi_dim}│ ${ansi_reset}${highlight_markdown_code(wrapped, language)}'
		}
	}
	lines << '${ansi_dim}└─${ansi_reset}'
	return lines
}

fn highlight_markdown_code(line string, language string) string {
	kind := language.to_lower()
	if kind in ['sh', 'shell', 'bash', 'zsh', 'fish'] {
		highlighted := highlight_shell('$ ' + line)
		return if highlighted.len >= 2 { highlighted[2..] } else { highlighted }
	}
	if kind in ['diff', 'patch'] {
		if line.starts_with('+') { return '\x1b[32m${line}${ansi_reset}' }
		if line.starts_with('-') { return '\x1b[31m${line}${ansi_reset}' }
		if line.starts_with('@@') { return '\x1b[36m${line}${ansi_reset}' }
	}
	return highlight_code_line(line, kind)
}

fn render_mermaid(source []string, width int) ?[]string {
	if source.len == 0 { return none }
	header := source[0].trim_space()
	if header.starts_with('flowchart') || header.starts_with('graph') {
		mut edges := []string{}
		mut seen := map[string]bool{}
		for raw in source[1..] {
			line := raw.trim_space()
			arrow := if line.contains('-->') {
				'-->'
			} else if line.contains('---') {
				'---'
			} else {
				continue
			}
			parts := line.split_nth(arrow, 2)
			if parts.len != 2 { return none }
			left := mermaid_label(parts[0])
			right := mermaid_label(parts[1])
			if seen['${right}->${left}'] { return none }
			seen['${left}->${right}'] = true
			edge := '[${left}] ${if arrow == '-->' { '→' } else { '—' }} [${right}]'
			if edge.len > width { return none }
			edges << edge
		}
		if edges.len == 0 { return none }
		return edges
	}
	if header == 'sequenceDiagram' {
		mut lines := []string{}
		for raw in source[1..] {
			line := raw.trim_space()
			arrow := if line.contains('->>') {
				'->>'
			} else if line.contains('-->>') {
				'-->>'
			} else {
				continue
			}
			parts := line.split_nth(arrow, 2)
			if parts.len != 2 { return none }
			to_message := parts[1].split_nth(':', 2)
			rendered := '${parts[0].trim_space()} ${if arrow == '->>' { '→' } else { '⇢' }} ${to_message[0].trim_space()}: ${if to_message.len == 2 {
				to_message[1].trim_space()
			} else {
				''
			}}'
			if rendered.len > width { return none }
			lines << rendered
		}
		if lines.len == 0 { return none }
		return lines
	}
	return none
}

fn mermaid_label(raw string) string {
	mut value := raw.trim_space()
	if value.contains('[') && value.contains(']') { value = value.all_after('[').all_before(']') }
	return value.trim(' "')
}

fn wrap_line(line string, width int, prefix string) []string {
	available := if width - prefix.len > 8 { width - prefix.len } else { 8 }
	if line.len <= available { return [prefix + line] }
	mut result := []string{}
	mut rest := line
	for rest.len > available {
		mut split := rest[..available].last_index(' ') or { available }
		if split <= 0 { split = available }
		result << prefix + rest[..split].trim_space()
		rest = rest[split..].trim_space()
	}
	result << prefix + rest
	return result
}

pub fn sanitize_terminal(source string) string {
	mut result := []u8{cap: source.len}
	bytes := source.bytes()
	mut index := 0
	for index < bytes.len {
		byte := bytes[index]
		if byte == 0x1b {
			index++
			if index < bytes.len && bytes[index] == `[` {
				index++
				for index < bytes.len && !(bytes[index] >= 0x40 && bytes[index] <= 0x7e) {
					index++
				}
				if index < bytes.len { index++ }
			}
			continue
		}
		if byte >= 0x20 || byte in [`\n`, `\t`] { result << byte }
		index++
	}
	return result.bytestr()
}

fn simple_hash(value string) u64 {
	mut hash := u64(1469598103934665603)
	for byte in value.bytes() {
		hash = (hash ^ byte) * 1099511628211
	}
	return hash
}
