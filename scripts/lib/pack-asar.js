const fs = require('fs')
const path = require('path')

const [source, destination] = process.argv.slice(2)
if (!source || !destination) {
  process.stderr.write('usage: node pack-asar.js <source-directory> <destination.asar>\n')
  process.exit(64)
}

const chunks = []
let offset = 0

function collect(directory) {
  const files = {}
  for (const name of fs.readdirSync(directory).sort()) {
    const fullPath = path.join(directory, name)
    const stat = fs.statSync(fullPath)
    if (stat.isDirectory()) {
      files[name] = { files: collect(fullPath) }
      continue
    }
    if (!stat.isFile()) continue
    const content = fs.readFileSync(fullPath)
    files[name] = { size: content.length, offset: String(offset) }
    chunks.push(content)
    offset += content.length
  }
  return files
}

function align(value, boundary) {
  return Math.ceil(value / boundary) * boundary
}

function uint32Pickle(value) {
  const result = Buffer.alloc(8)
  result.writeUInt32LE(4, 0)
  result.writeUInt32LE(value, 4)
  return result
}

function stringPickle(value) {
  const text = Buffer.from(value, 'utf8')
  const payloadSize = align(4 + text.length + 1, 4)
  const result = Buffer.alloc(4 + payloadSize)
  result.writeUInt32LE(payloadSize, 0)
  result.writeUInt32LE(text.length, 4)
  text.copy(result, 8)
  return result
}

const header = stringPickle(JSON.stringify({ files: collect(path.resolve(source)) }))
const archive = Buffer.concat([uint32Pickle(header.length), header, ...chunks])
fs.mkdirSync(path.dirname(path.resolve(destination)), { recursive: true })
fs.writeFileSync(destination, archive)
