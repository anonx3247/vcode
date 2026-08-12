module vc

import json
import os
import time

pub struct RecapScheduler {
pub mut:
	completed_turns int
	last_recap_ms   i64
	last_event_seq  u64
}

pub fn (mut scheduler RecapScheduler) should_recap(now_ms i64, latest_seq u64) bool {
	scheduler.completed_turns++
	first := scheduler.completed_turns == 1
	active_ten_minutes := scheduler.last_recap_ms > 0
		&& now_ms - scheduler.last_recap_ms >= 10 * 60 * 1000
	if latest_seq > scheduler.last_event_seq && (first || active_ten_minutes) {
		scheduler.last_recap_ms = now_ms
		scheduler.last_event_seq = latest_seq
		return true
	}
	return false
}

pub fn generate_recap(model SmallModel, transcript string) !string {
	recap :=
		model.complete('Write one plain sentence recapping this coding session.', transcript, 80)!
	return recap.replace('\n', ' ').trim_space()
}

pub struct GoalState {
pub mut:
	goal   string
	paused bool
}

pub fn save_goal(session_id string, state GoalState) ! {
	os.write_file(os.join_path(session_dir(session_id), 'goal.json'), json.encode(state))!
}

pub fn load_goal(session_id string) GoalState {
	return json.decode(GoalState, os.read_file(os.join_path(session_dir(session_id), 'goal.json')) or {
		return GoalState{}
	}) or { GoalState{} }
}

pub fn evaluate_goal(model SmallModel, goal string, transcript string) !string {
	return model.complete('Judge whether the goal is fully achieved. Reply exactly <goal achieved> or give concise missing-work guidance.',
		'Goal: ${goal}\n\nTranscript:\n${transcript}', 256)!
}

pub struct ReviewContext {
pub:
	instructions string
	tools        []string
	cwd          string
	model        string
}

pub fn build_review_context(cwd string, model string) !ReviewContext {
	return ReviewContext{
		instructions: load_review_instructions(cwd)!
		tools:        ['Read', 'WebSearch', 'Shell']
		cwd:          os.real_path(cwd)
		model:        model
	}
}

pub fn run_review(model SmallModel, context ReviewContext, instructions string) !string {
	return model.complete('${context.instructions}\nYou are a fresh review agent. You cannot edit files.',
		instructions, 4096)!
}

fn load_review_instructions(cwd string) !string {
	mut dirs := []string{}
	mut dir := os.real_path(cwd)
	for {
		dirs.prepend(dir)
		parent := os.dir(dir)
		if parent == dir { break
		 }
		dir = parent
	}
	mut content := ''
	for candidate in dirs {
		path := os.join_path(candidate, 'REVIEW.md')
		if os.is_file(path) { content += os.read_file(path)! + '\n' }
	}
	return content
}

pub fn mark_session_recap(mut meta SessionMeta, recap string) ! {
	meta.recap = recap
	meta.updated_ms = time.now().unix_milli()
	save_session_meta(meta)!
}
