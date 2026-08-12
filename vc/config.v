module vc

import os
import time

pub struct ModelRef {
pub:
	provider string
	model    string
}

pub fn parse_model_ref(raw string) !ModelRef {
	parts := raw.split_nth(':', 2)
	if parts.len != 2 || parts[0].trim_space() == '' || parts[1].trim_space() == '' {
		return error('model must be provider:model')
	}
	return ModelRef{
		provider: parts[0].trim_space()
		model:    parts[1].trim_space()
	}
}

pub struct ProviderConfig {
pub mut:
	name         string
	kind         string
	base_url     string
	base_url_env string
	api_key      string
	api_key_env  string
	alias        string
}

pub struct Config {
pub mut:
	default_model string = 'openai:gpt-5.2'
	effort        string = 'medium'
	small_model   string = 'openai:gpt-5-mini'
	providers     map[string]ProviderConfig
}

pub fn config_path() string {
	base := os.getenv_opt('XDG_CONFIG_HOME') or { os.join_path(os.home_dir(), '.config') }
	return os.join_path(base, 'vc', 'config.toml')
}

pub fn load_config(path string) !Config {
	mut cfg := Config{}
	if !os.exists(path) {
		return cfg
	}
	mut section := ''
	for source_line in os.read_lines(path)! {
		line := source_line.trim_space()
		if line == '' || line.starts_with('#') {
			continue
		}
		if line.starts_with('[') && line.ends_with(']') {
			section = line[1..line.len - 1].trim_space()
			continue
		}
		pair := line.split_nth('=', 2)
		if pair.len != 2 {
			continue
		}
		key := pair[0].trim_space()
		value := pair[1].trim_space().trim('"').trim("'")
		if section.starts_with('providers.') {
			name := section.all_after('providers.')
			mut provider := cfg.providers[name] or {
				ProviderConfig{
					name: name
				}
			}
			match key {
				'kind' { provider.kind = value }
				'base_url' { provider.base_url = value }
				'base_url_env' { provider.base_url_env = value }
				'api_key' { provider.api_key = value }
				'api_key_env' { provider.api_key_env = value }
				'alias' { provider.alias = value }
				else {}
			}

			cfg.providers[name] = provider
		} else {
			match key {
				'default_model' { cfg.default_model = value }
				'effort' { cfg.effort = value }
				'small_model' { cfg.small_model = value }
				else {}
			}
		}
	}
	parse_model_ref(cfg.default_model)!
	parse_model_ref(cfg.small_model)!
	return cfg
}

pub fn save_config(cfg Config, path string) ! {
	os.mkdir_all(os.dir(path))!
	mut body := 'default_model = "${cfg.default_model}"\neffort = "${cfg.effort}"\nsmall_model = "${cfg.small_model}"\n'
	for name, provider in cfg.providers {
		body += '\n[providers.${name}]\nkind = "${provider.kind}"\nbase_url = "${provider.base_url}"\n'
		if provider.base_url_env != '' { body += 'base_url_env = "${provider.base_url_env}"\n' }
		if provider.api_key != '' {
			body += 'api_key = "${provider.api_key}"\n'
		}
		if provider.api_key_env != '' { body += 'api_key_env = "${provider.api_key_env}"\n' }
		if provider.alias != '' {
			body += 'alias = "${provider.alias}"\n'
		}
	}
	tmp := '${path}.${time.now().unix_milli()}.tmp'
	os.write_file(tmp, body)!
	os.mv(tmp, path)!
}
