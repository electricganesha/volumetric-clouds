import json

found = False
with open('/Users/cmarques/.gemini/antigravity-ide/brain/eca0fdac-8f15-4f37-87a9-ceea7f03ba81/.system_generated/logs/transcript_full.jsonl') as f:
    for line in f:
        try:
            data = json.loads(line)
            if data.get('type') == 'VIEW_FILE':
                content = data.get('content', '')
                if 'for (int i = 0; i < MAX_STEPS; i++)' in content:
                    print("Found in VIEW_FILE, Step:", data.get('step_index'))
                    lines = content.split('\n')
                    for i, r in enumerate(lines):
                        if 'for (int i = 0; i < MAX_STEPS; i++)' in r:
                            # Print 100 lines below
                            for j in range(i, min(len(lines), i + 100)):
                                print(lines[j])
                            print("---------------------------------")
                            found = True
                            break
        except:
            pass
        if found:
            break
