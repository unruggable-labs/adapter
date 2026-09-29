"""Independently verify Rust miner output and reconstruct both init codes with Python Keccak.
No forge/cast CREATE2 helper or miner hashing implementation is used in this verification.
"""
import json,pathlib,re
from Crypto.Hash import keccak
P=pathlib.Path('output')
def kh(data):h=keccak.new(digest_bits=256);h.update(data);return h.digest()
def raw(s):return bytes.fromhex(s.removeprefix('0x'))
def word(n):return n.to_bytes(32,'big')
def addrword(a):return b'\0'*12+raw(a)
def predict(factory,salt,init):return kh(b'\xff'+raw(factory)+salt+kh(init))[-20:]
def checksum(address):
 lower=address.hex();hashed=kh(lower.encode()).hex()
 return '0x'+''.join(c.upper() if int(hashed[i],16)>=8 else c for i,c in enumerate(lower))
factory='0x4e59b44847b379578588920cA78FbF26c0B4956C';registry='0x8004A169FB4a3325136EB29fA0ceB6D2e539a432';owner='0x03302Df40186D9B85faEA4fbb6cC5da028B23149'
implcode=raw(json.load(open('out/AdapterImplementation.sol/AdapterImplementation.json'))['bytecode']['object'])
proxycode=raw(json.load(open('out/ERC1967Proxy.sol/ERC1967Proxy.json'))['bytecode']['object'])
implinit=implcode+addrword(registry);impl=predict(factory,b'\0'*32,implinit)
assert kh(implinit).hex()=='5b3785cf0fbcd80f67ead4953f7a775604ad6f9bbbba55040810e25f1aef1558'
assert checksum(impl)=='0x3d74ff0c1E0A78C5a291fA91F82f15bd54335231'
init=kh(b'initialize(address)')[:4]+addrword(owner)
proxyinit=proxycode+b'\0'*12+impl+word(64)+word(len(init))+init+b'\0'*((-len(init))%32)
assert kh(proxyinit).hex()=='bb43a76de1130e845b39e4d6ff11934b8ccf9b4aae11084e955d7f7219cc9953'
assert proxyinit==raw(P.joinpath('robinhood-proxy-init.hex').read_text().strip())
text=P.joinpath('robinhood-vanity-1800s.log').read_text();assert 'budget          1800s' in text and 'threads         12' in text and 'panic' not in text.lower()
final=text.split('=== best ===')[1]
salt=re.search(r'^salt\s+(0x[0-9a-f]{64})$',final,re.M)[1]
reported=re.search(r'^address\s+(0x[0-9a-f]{40})$',final,re.M)[1]
count=int(re.search(r'^leading zeros\s+(\d+) nibbles',final,re.M)[1])
attempts=int(re.search(r'^attempts\s+(\d+)',final,re.M)[1]);elapsed=float(re.search(r'^elapsed\s+([0-9.]+)s',final,re.M)[1]);assert elapsed>=1800
address=predict(factory,raw(salt),proxyinit);assert address==raw(reported)
assert len(address.hex())-len(address.hex().lstrip('0'))==count
result={'factory':factory,'registry':registry,'owner':owner,'implementationInitCodeHash':'0x'+kh(implinit).hex(),'implementation':checksum(impl),'proxyInitCodeHash':'0x'+kh(proxyinit).hex(),'salt':salt,'address':checksum(address),'leadingZeroNibbles':count,'leadingZeroBytes':count//2,'attempts':attempts,'elapsedSeconds':elapsed,'threads':12,'budgetSeconds':1800,'verification':'Independent Python PyCryptodome Keccak + manual ABI encoding + CREATE2 formula','create2Preimage':'0x'+(b'\xff'+raw(factory)+raw(salt)+kh(proxyinit)).hex()}
P.joinpath('robinhood-mined-result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
