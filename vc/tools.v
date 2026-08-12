module vc

import crypto.sha256
import net.http
import os

pub struct ReadResult {
pub:
	path        string
	content     string
	fingerprint string
	truncated   bool
}

pub fn read_tool(path string, max_bytes int) !ReadResult {
	real := os.real_path(path)
	content := os.read_file(real)!
	limit := if max_bytes > 0 { max_bytes } else { 1024 * 1024 }
	shown := if content.len > limit { content[..limit] } else { content }
	return ReadResult{
		path:        real
		content:     shown
		fingerprint: sha256.hexhash(content)
		truncated:   content.len > limit
	}
}

pub fn edit_tool(path string, old string, replacement string, fingerprint string) !string {
	if old == '' { return error('old text cannot be empty') }
	current := os.read_file(path)!
	if sha256.hexhash(current) != fingerprint { return error('file changed since Read') }
	if current.count(old) != 1 { return error('old text must occur exactly once') }
	updated := current.replace_once(old, replacement)
	tmp := '${path}.vc.tmp'
	os.write_file(tmp, updated)!
	os.mv(tmp, path)!
	return sha256.hexhash(updated)
}

pub fn brave_web_search(query string, api_key string, max_bytes int) !string {
	if api_key == '' { return error('BRAVE_API_KEY is not configured') }
	url := 'https://api.search.brave.com/res/v1/web/search?q=${query.replace(' ', '%20')}'
	mut request := http.new_request(.get, url, '')
	request.add_custom_header('X-Subscription-Token', api_key)!
	response := request.do()!
	if response.status_code < 200 || response.status_code >= 300 {
		return error('Brave returned HTTP ${response.status_code}')
	}
	limit := if max_bytes > 0 { max_bytes } else { 256 * 1024 }
	return if response.body.len > limit { response.body[..limit] } else { response.body }
}
