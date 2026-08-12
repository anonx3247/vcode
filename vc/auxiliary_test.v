module vc

struct FakeSmallModel {
	answer string
}

fn (model FakeSmallModel) complete(system string, prompt string, max_tokens int) !string {
	_ = system
	_ = prompt
	_ = max_tokens
	return model.answer
}

fn test_compaction_preserves_transcript_and_checkpoints() {
	mut transcript := []ContextItem{}
	for index in 0 .. 30 {
		transcript << ContextItem{
			seq:     u64(index + 1)
			kind:    if index % 3 == 0 { 'tool_result' } else { 'text' }
			content: 'x'.repeat(120)
			tokens:  30
		}
	}
	original := transcript.clone()
	projection := project_context(transcript, 1000, 'small:test', FakeSmallModel{ answer: 'summary' }) or {
		panic(err)
	}
	assert transcript == original
	assert projection.items.len < transcript.len
	checkpoint := projection.checkpoint or { panic('expected checkpoint') }
	assert checkpoint.input_hash.len == 64
	assert checkpoint.result == 'summary'
}

fn test_recap_schedule_first_then_ten_minutes() {
	mut scheduler := RecapScheduler{}
	assert scheduler.should_recap(1000, 1)
	assert !scheduler.should_recap(2000, 2)
	assert scheduler.should_recap(1000 + 10 * 60 * 1000, 3)
}

fn test_review_has_no_edit_tool() {
	context := build_review_context('.', 'openai:test') or { panic(err) }
	assert 'Edit' !in context.tools
}
