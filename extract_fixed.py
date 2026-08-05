import json

def extract_original(file_path, view_steps):
    lines_dict = {}
    with open('/Users/cmarques/.gemini/antigravity-ide/brain/eca0fdac-8f15-4f37-87a9-ceea7f03ba81/.system_generated/logs/transcript_full.jsonl') as f:
        for line in f:
            try:
                data = json.loads(line)
                if data.get('step_index') in view_steps and data.get('type') == 'VIEW_FILE':
                    content = data.get('content', '')
                    for row in content.split('\n'):
                        if ': ' in row:
                            parts = row.split(': ', 1)
                            if parts[0].isdigit():
                                line_num = int(parts[0])
                                # Only keep the FIRST time this line is seen
                                if line_num not in lines_dict:
                                    lines_dict[line_num] = parts[1]
            except Exception as e:
                pass
    
    # Sort and write
    sorted_lines = [lines_dict[i] for i in sorted(lines_dict.keys())]
    with open(file_path, 'w') as f:
        f.write('\n'.join(sorted_lines))
    print(f"Extracted {len(sorted_lines)} lines for {file_path}")

# main.ts was viewed first at step 23 (1-250) and step 26 (251-794).
extract_original('src/main.ts', [23, 26])
# VolumetricCloudMaterial.ts was viewed at step 29 (1-200)
extract_original('src/materials/VolumetricCloudMaterial.ts', [29])
# compositeFragment.glsl was viewed at step 32 (1-200)
extract_original('src/shaders/compositeFragment.glsl', [32])
# cloudFragment.glsl was viewed at step 35 (1-250), step 47 (250-350), step 53 (315-328), step 536 (8-25), step 629 (500-530), step 653 (340-370)
# Let's just collect from all VIEW_FILE steps that happened before step 100, plus the end of the file that was viewed later
extract_original('src/shaders/cloudFragment.glsl', [35, 47, 53, 275, 386, 536, 611, 614, 617, 620, 629, 653, 665, 692, 710])
