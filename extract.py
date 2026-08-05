import json

def get_file_content(step_index):
    lines = []
    with open('/Users/cmarques/.gemini/antigravity-ide/brain/eca0fdac-8f15-4f37-87a9-ceea7f03ba81/.system_generated/logs/transcript_full.jsonl') as f:
        for line in f:
            try:
                data = json.loads(line)
                if data.get('step_index') == step_index and data.get('type') == 'VIEW_FILE':
                    content = data.get('content', '')
                    # Extract the lines which are prefixed with "<line_number>: "
                    for row in content.split('\n'):
                        if ': ' in row:
                            parts = row.split(': ', 1)
                            if parts[0].isdigit():
                                lines.append((int(parts[0]), parts[1]))
            except:
                pass
    return lines

main_ts_lines = get_file_content(23) + get_file_content(26)
main_ts_lines = sorted(list(set(main_ts_lines)))

with open('src/main.ts', 'w') as f:
    for _, line in main_ts_lines:
        f.write(line + '\n')
print(f"Extracted {len(main_ts_lines)} lines for main.ts")
