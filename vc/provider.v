module vc

import json
import net.http
import os
import time

pub struct ModelCache {
pub:
	provider   string
	models     []string
	fetched_ms i64
}

pub fn cache_models(provider string, models []string) ! {
	path := os.join_path(state_dir(), 'models', '${provider}.json')
	os.mkdir_all(os.dir(path))!
	os.write_file(path, json.encode(ModelCache{
		provider:   provider
		models:     models
		fetched_ms: time.now().unix_milli()
	}))!
}

pub fn cached_models(provider string, max_age time.Duration) ![]string {
	path := os.join_path(state_dir(), 'models', '${provider}.json')
	cache := json.decode(ModelCache, os.read_file(path)!)!
	if time.now().unix_milli() - cache.fetched_ms > max_age.milliseconds() {
		return error('model cache expired')
	}
	return cache.models.map('${provider}:${it}')
}

pub fn model_catalog(cfg Config) ![]string {
	mut result := []string{}
	mut failures := []string{}
	if cfg.providers.len == 0 {
		return error('no providers configured in ${config_path()}')
	}
	for name, provider in cfg.providers {
		if cached := cached_models(name, 15 * time.minute) {
			result << cached
			continue
		}
		models := fetch_provider_models(name, provider) or {
			failures << '${name}: ${err.msg()}'
			continue
		}
		cache_models(name, models) or {}
		result << models.map('${name}:${it}')
	}
	if result.len == 0 {
		return error('model discovery failed: ${failures.join('; ')}')
	}
	result.sort()
	return result
}

fn fetch_provider_models(name string, provider ProviderConfig) ![]string {
	kind := provider_kind(name, provider)!
	key := provider_api_key(kind, provider)
	if key == '' { return error('no API key') }
	base := provider_base_url(kind, provider)
	mut request := http.new_request(.get, '${base}/models', '')
	request.enable_http2 = false
	request.read_timeout = 10 * time.second
	request.write_timeout = 10 * time.second
	if kind == 'openai' {
		request.add_header(.authorization, 'Bearer ${key}')
	} else {
		request.add_custom_header('x-api-key', key)!
		request.add_custom_header('anthropic-version', '2023-06-01')!
	}
	response := request.do()!
	if response.status_code < 200 || response.status_code >= 300 {
		return error('HTTP ${response.status_code}')
	}
	mut models := []string{}
	mut rest := response.body
	for rest.contains('"id"') {
		index := rest.index('"id"') or { break }
		rest = rest[index..]
		id := json_field(rest, 'id')
		if id != '' && id !in models { models << id }
		rest = rest[4..]
	}
	if models.len == 0 { return error('empty model list') }
	return models
}
