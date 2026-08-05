import json

def get_reversions():
    reversions = []
    with open('/Users/cmarques/.gemini/antigravity-ide/brain/eca0fdac-8f15-4f37-87a9-ceea7f03ba81/.system_generated/logs/transcript_full.jsonl') as f:
        for line in f:
            try:
                data = json.loads(line)
                if 'tool_calls' in data:
                    for call in data['tool_calls']:
                        if call['name'] == 'replace_file_content':
                            args = call['args']
                            if 'TargetContent' in args and 'ReplacementContent' in args:
                                reversions.append({
                                    'file': args['TargetFile'],
                                    'target': args['TargetContent'],
                                    'replacement': args['ReplacementContent']
                                })
                        elif call['name'] == 'multi_replace_file_content':
                            args = call['args']
                            if 'ReplacementChunks' in args:
                                chunks = args['ReplacementChunks']
                                if isinstance(chunks, str):
                                    chunks = json.loads(chunks)
                                for chunk in chunks:
                                    if 'TargetContent' in chunk and 'ReplacementContent' in chunk:
                                        reversions.append({
                                            'file': args['TargetFile'],
                                            'target': chunk['TargetContent'],
                                            'replacement': chunk['ReplacementContent']
                                        })
            except Exception as e:
                pass
    return reversions

reversions = get_reversions()
print(f"Found {len(reversions)} replacement actions.")
reversions.reverse()

file_contents = {}

def read_file(path):
    if path not in file_contents:
        try:
            with open(path, 'r') as f:
                file_contents[path] = f.read()
        except:
            file_contents[path] = ""
    return file_contents[path]

for rev in reversions:
    path = rev['file']
    content = read_file(path)
    
    # We want to replace 'replacement' with 'target'
    rep = rev['replacement']
    tgt = rev['target']
    
    if rep in content:
        content = content.replace(rep, tgt, 1)
        file_contents[path] = content
    else:
        print(f"Could not find replacement block in {path}")
        print("Expected:", rep[:100] + "...")

for path, content in file_contents.items():
    with open(path, 'w') as f:
        f.write(content)
        
print("Reversion complete.")
