const dgram = require("node:dgram")
const s = dgram.createSocket({ type: "udp4", reuseAddr: true })
const timer = setTimeout(() => { console.log("NO_BEACON"); process.exit(1) }, 8000)
s.on("message", (msg) => {
  const b = JSON.parse(msg.toString())
  if (b.service !== "dsh-mobile-bridge") return
  clearTimeout(timer)
  console.log(JSON.stringify({ name: b.name, host: b.host, port: b.port, dsh: b.dsh ?? null, token: b.token ?? null, hasAddresses: Array.isArray(b.addresses) }))
  s.close(); process.exit(0)
})
s.bind(5181)
