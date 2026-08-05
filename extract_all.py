import json
import os

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

mat_lines = get_file_content([29])
with open('src/materials/VolumetricCloudMaterial.ts', 'w') as f:
    f.write('\n'.join(mat_lines))
print(f"Extracted {len(mat_lines)} lines for VolumetricCloudMaterial.ts")

cloud_lines = get_file_content([35, 47, 53, 536, 629, 653, 665, 692, 710])
with open('src/shaders/cloudFragment.glsl', 'w') as f:
    f.write('\n'.join(cloud_lines))
print(f"Extracted {len(cloud_lines)} lines for cloudFragment.glsl")
