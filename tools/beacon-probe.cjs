const dgram = require('node:dgram')
const socket = dgram.createSocket({ type: 'udp4', reuseAddr: true })
let count = 0
socket.on('message', (msg, rinfo) => {
  count += 1
  if (count <= 2) console.log('beacon from', rinfo.address + ':' + rinfo.port, msg.toString())
})
socket.bind(5181, () => console.log('listening on 5181 for 7s...'))
setTimeout(() => { console.log('beacons received:', count); socket.close(); process.exit(0) }, 7000)
