import json,subprocess,concurrent.futures,collections,sys,time
url,addr,start,end=sys.argv[1],sys.argv[2],int(sys.argv[3]),int(sys.argv[4])
step=2000
def scan(s):
    body=json.dumps({'jsonrpc':'2.0','id':1,'method':'eth_getLogs','params':[{'address':addr,'fromBlock':hex(s),'toBlock':hex(min(s+step-1,end))}]})
    for attempt in range(6):
        try:
            r=json.loads(subprocess.check_output(['curl','-sS','--max-time','30',url,'-H','Content-Type: application/json','-d',body],text=True))
            if 'error' in r: time.sleep(1+attempt); continue
            return s,r['result']
        except Exception: time.sleep(1+attempt)
    return s,None
c=collections.Counter(); first={}; failed=[]
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    for s,logs in pool.map(scan,range(start,end+1,step)):
        if logs is None: failed.append(s); continue
        for l in logs:
            t=l['topics'][0]; c[t]+=1; first.setdefault(t,int(l['blockNumber'],16))
print(json.dumps({'counts':c,'first':first,'failed':failed}))
