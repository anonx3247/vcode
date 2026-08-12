module vc

import json
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
