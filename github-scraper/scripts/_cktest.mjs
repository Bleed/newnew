import crypto from 'node:crypto'
import { readFile } from 'node:fs/promises'
const [action, arg] = process.argv.slice(2)
const keyID = '07145f1f3eedafa3bc7ef667a642d82732d521132b4b78d1bccbc2c310d3726a'
const privateKey = process.env.CLOUDKIT_PRIVATE_KEY
async function call(op, body) {
  const subpath = `/database/1/iCloud.com.svein.newnew/production/public/records/${op}`
  const text = JSON.stringify(body)
  const date = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')
  const hash = crypto.createHash('sha256').update(text).digest('base64')
  const sig = crypto.sign('sha256', Buffer.from(`${date}:${hash}:${subpath}`), privateKey).toString('base64')
  const r = await fetch('https://api.apple-cloudkit.com' + subpath, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Apple-CloudKit-Request-KeyID': keyID, 'X-Apple-CloudKit-Request-ISO8601Date': date, 'X-Apple-CloudKit-Request-SignatureV1': sig }, body: text })
  return [r.status, await r.json()]
}
if (action === 'create') {
  const feed = JSON.parse(await readFile(arg, 'utf8'))
  const a = feed.articles.find(x => x.category === 'World' && x.imageURL) ?? feed.articles[0]
  const [status, res] = await call('modify', { operations: [{ operationType: 'create', record: { recordType: 'Breaking', fields: { headline: { value: `newnew test: breaking push · ${a.title}` }, url: { value: a.url }, outlets: { value: 5 } } } }] })
  console.log(status, JSON.stringify(res.records?.map(r => ({ recordName: r.recordName, headline: r.fields?.headline?.value, err: r.serverErrorCode, reason: r.reason }))))
} else if (action === 'delete') {
  const [status, res] = await call('modify', { operations: [{ operationType: 'forceDelete', record: { recordName: arg } }] })
  console.log(status, JSON.stringify(res.records?.map(r => ({ recordName: r.recordName, deleted: r.deleted, err: r.serverErrorCode }))))
}
