use chorograph_plugin_sdk_rust::prelude::*;
use serde_json::json;

struct GeminiCLI;

impl GeminiCLI {
    fn format_skeletons(&self, payload: &serde_json::Value) -> String {
        let mut context = String::new();
        if let Some(skeletons) = payload.get("skeletons").and_then(|s| s.as_array()) {
            if !skeletons.is_empty() {
                context.push_str("\n\n### Project Structure Context (AST Skeletons):\n");
                for skel in skeletons {
                    if let (Some(path), Some(symbols)) = (
                        skel.get("path").and_then(|p| p.as_str()),
                        skel.get("symbols").and_then(|s| s.as_array())
                    ) {
                        context.push_str(&format!("\nFile: `{}`\n", path));
                        for sym in symbols {
                            if let (Some(name), Some(kind), Some(line)) = (
                                sym.get("name").and_then(|n| n.as_str()),
                                sym.get("kind").and_then(|k| k.as_str()),
                                sym.get("line").and_then(|l| l.as_u64())
                            ) {
                                context.push_str(&format!("  - {} `{}` (line {})\n", kind, name, line));
                            }
                        }
                    }
                }
            }
        }
        context
    }

    fn run_gemini(&self, session_id: &str, prompt: &str, is_plan: bool) -> Result<()> {
        log!("[Gemini Plugin] Spawning gemini for session={}", session_id);
        
        // Wrap in bash -lc to ensure shims and environment are active
        let child = ChildProcess::spawn(
            "bash",
            vec![
                "-lc",
                &format!("gemini --json \"{}\"", prompt.replace("\"", "\\\""))
            ],
            None,
            std::collections::HashMap::new()
        )?;

        let mut buffer = Vec::new();
        let mut full_response = String::new();

        while child.wait_for_data(60000) {
            if let Ok(ReadResult::Data(err_data)) = child.read(PipeType::Stderr) {
                if !err_data.is_empty() {
                    let err_msg = String::from_utf8_lossy(&err_data);
                    log!("[Gemini Plugin] Stderr: {}", err_msg);
                }
            }

            match child.read(PipeType::Stdout)? {
                ReadResult::Data(data) => {
                    buffer.extend(data);
                    while let Some(pos) = buffer.iter().position(|&b| b == b'\n') {
                        let line = buffer.drain(..=pos).collect::<Vec<_>>();
                        if let Ok(val) = serde_json::from_slice::<serde_json::Value>(&line) {
                            if val.get("type") == Some(&json!("item.completed")) {
                                if let Some(item) = val.get("item") {
                                    let item_type = item.get("type").and_then(|t| t.as_str());
                                    if item_type == Some("agent_message") {
                                        if let Some(msg) = item.get("text").and_then(|t| t.as_str()) {
                                            if is_plan { full_response.push_str(msg); }
                                            push_ai_event(session_id, &AIEvent::StreamingDelta {
                                                session_id: session_id.to_string(),
                                                text: msg.to_string(),
                                            });
                                        }
                                    } else if item_type == Some("reasoning") {
                                        if let Some(msg) = item.get("text").and_then(|t| t.as_str()) {
                                            push_ai_event(session_id, &AIEvent::Reasoning {
                                                session_id: session_id.to_string(),
                                                text: msg.to_string(),
                                            });
                                        }
                                    }
                                }
                            }
                        } else {
                            let text = String::from_utf8_lossy(&line).to_string();
                            if is_plan { full_response.push_str(&text); }
                            push_ai_event(session_id, &AIEvent::StreamingDelta {
                                session_id: session_id.to_string(),
                                text,
                            });
                        }
                    }
                }
                ReadResult::EOF => break,
                ReadResult::Empty => continue,
            }
        }

        if is_plan {
            let files = self.extract_files(&full_response);
            if !files.is_empty() {
                push_ai_event(session_id, &AIEvent::PlanGenerated {
                    session_id: session_id.to_string(),
                    files,
                });
            }
        }

        push_ai_event(session_id, &AIEvent::TurnCompleted {
            session_id: session_id.to_string(),
        });

        Ok(())
    }

    fn extract_files(&self, response: &str) -> Vec<String> {
        if let Some(last_start) = response.rfind('[') {
            if let Some(last_end) = response.rfind(']') {
                if last_end > last_start {
                    let json_part = &response[last_start..=last_end];
                    if let Ok(files) = serde_json::from_str::<Vec<String>>(json_part) {
                        return files;
                    }
                }
            }
        }
        Vec::new()
    }
}

#[chorograph_plugin]
pub fn init() {
    let ui = json!([
        { "type": "label", "text": "Gemini CLI (Rust WASM)" }
    ]);
    push_ui(&ui.to_string());
}

#[chorograph_plugin]
pub fn handle_action(action_id: String, payload: serde_json::Value) {
    let provider = GeminiCLI;
    log!("[Gemini Plugin] handle_action id={} payload={}", action_id, payload);
    
    let context = provider.format_skeletons(&payload);
    
    if let (Some(session_id), Some(prompt)) = (
        payload.get("session_id").and_then(|s| s.as_str()),
        payload.get("prompt").and_then(|p| p.as_str())
    ) {
        let final_prompt = format!("{}{}", prompt, context);
        
        if action_id == "plan" {
            let plan_prompt = format!(
                "Analyze the task: {}. \n\n\
                Respond in two clear parts:\n\
                1. A detailed Markdown summary of your plan using headings (###), bullet points, and paragraphs.\n\
                2. A single JSON array of ALL relevant relative file paths (both to read and to modify) at the very end.\n\n\
                Example format:\n\
                ### Summary\n\
                I will analyze...\n\n\
                [\"file1.swift\", \"file2.swift\"]", 
                final_prompt
            );
            let _ = provider.run_gemini(session_id, &plan_prompt, true);
        } else if action_id == "engage" {
            let _ = provider.run_gemini(session_id, &final_prompt, false);
        }
    }
}
