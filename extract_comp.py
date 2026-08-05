import json

def get_file_content(step_indices):
    lines = []
    with open('/Users/cmarques/.gemini/antigravity-ide/brain/eca0fdac-8f15-4f37-87a9-ceea7f03ba81/.system_generated/logs/transcript_full.jsonl') as f:
        for line in f:
            try:
                data = json.loads(line)
                if data.get('step_index') in step_indices and data.get('type') == 'VIEW_FILE':
                    content = data.get('content', '')
                    for row in content.split('\n'):
                        if ': ' in row:
                            parts = row.split(': ', 1)
                            if parts[0].isdigit():
                                lines.append((int(parts[0]), parts[1]))
            except:
                pass
    lines = sorted(list(set(lines)))
    return [l[1] for l in lines]

comp_lines = get_file_content([32]) # Wait, let me check what step VIEW_FILE was. Step 31 was PLANNER_RESPONSE, so step 32 must be VIEW_FILE.
with open('src/shaders/compositeFragment.glsl', 'w') as f:
    f.write('\n'.join(comp_lines))
print(f"Extracted {len(comp_lines)} lines for compositeFragment.glsl")
