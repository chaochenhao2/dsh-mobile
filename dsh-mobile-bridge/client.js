window.__ModuleLoader__.load({
  id: 'dsh-mobile-bridge',
  factory(require) {
    const React = require('react')
    const h = React.createElement

    /** The bridge listens here; the panel talks to it over loopback. */
    const BASE = 'http://127.0.0.1:5180'

    /** Dictionaries inlined: a browser module cannot import JSON resources. */
    const ZH = {
          "panelTitle": "DSH Mobile",
          "heading": "DSH Mobile",
          "tagline": "用手机控制这台电脑上的 DeepSeek Harness。在手机上配对一次，之后自动连接。",
          "pairingSection": "配对信息",
          "pairingHint": "在手机上填这两项",
          "fieldAddress": "地址",
          "fieldPort": "端口",
          "fieldToken": "令牌",
          "fieldConfig": "配置文件",
          "otherAddresses": "其他可用地址：{addresses}",
          "devicesSection": "已配对手机",
          "devicesNone": "还没有",
          "devicesCount": "{count} 台",
          "devicesEmpty": "打开手机上的 DSH Mobile，填入上面的地址与令牌即可完成配对。",
          "hostSection": "这台电脑",
          "fieldName": "名称",
          "fieldDeviceId": "设备 ID",
          "fieldHarness": "Harness",
          "fieldBridge": "桥接版本",
          "fieldDiscovery": "局域网发现",
          "discoveryOn": "已开启，端口 {port}",
          "discoveryOff": "已关闭",
          "copy": "复制",
          "copied": "已复制",
          "loading": "读取中…",
          "loadFailed": "无法读取桥接状态：{reason}",
          "loadFailedHint": "如果桥接插件未启用，请在「插件」页启用它。"
    }
    const EN = {
          "panelTitle": "DSH Mobile",
          "heading": "DSH Mobile",
          "tagline": "Control this DeepSeek Harness from your phone. Pair once, then it connects on its own.",
          "pairingSection": "Pairing",
          "pairingHint": "Enter these two on the phone",
          "fieldAddress": "Address",
          "fieldPort": "Port",
          "fieldToken": "Token",
          "fieldConfig": "Config file",
          "otherAddresses": "Other reachable addresses: {addresses}",
          "devicesSection": "Paired phones",
          "devicesNone": "None yet",
          "devicesCount": "{count} paired",
          "devicesEmpty": "Open DSH Mobile on the phone and enter the address and token above to pair.",
          "hostSection": "This computer",
          "fieldName": "Name",
          "fieldDeviceId": "Device ID",
          "fieldHarness": "Harness",
          "fieldBridge": "Bridge version",
          "fieldDiscovery": "LAN discovery",
          "discoveryOn": "On, port {port}",
          "discoveryOff": "Off",
          "copy": "Copy",
          "copied": "Copied",
          "loading": "Loading…",
          "loadFailed": "Could not read bridge state: {reason}",
          "loadFailedHint": "If the bridge plugin is disabled, enable it on the Plugins page."
    }

    /** Locale namespace this panel registers its dictionaries under. */
    const NS = 'mobile-bridge'

    /**
     * Fill `{name}` placeholders in one dictionary entry.
     * @param text - the template.
     * @param values - substitution values.
     * @returns the filled string.
     */
    function fill(text, values) {
      return String(text).replace(/\{(\w+)\}/g, (whole, key) =>
        values[key] === undefined ? whole : String(values[key]))
    }

    /**
     * Read the panel state from the bridge.
     *
     * `/api/panel/state` is loopback-only and needs no token, because this page
     * runs on the same machine and cannot already hold the token it displays.
     */
    async function fetchPanelState() {
      const response = await fetch(`${BASE}/api/panel/state`)
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      return response.json()
    }

    function CopyButton({ value, t }) {
      const [copied, setCopied] = React.useState(false)
      return h('button', {
        type: 'button',
        onClick: () => {
          navigator.clipboard?.writeText(String(value)).then(() => {
            setCopied(true)
            setTimeout(() => setCopied(false), 1400)
          })
        },
        style: {
          flex: 'none',
          fontSize: 11,
          padding: '4px 10px',
          borderRadius: 6,
          cursor: 'pointer',
          border: '1px solid var(--dsh-border, rgba(128,128,128,0.3))',
          background: 'transparent',
          color: 'inherit',
        },
      }, copied ? t('copied') : t('copy'))
    }

    function Field({ label, value, mono = true, copyable = false, t }) {
      return h('div', {
        style: {
          display: 'flex',
          alignItems: 'center',
          gap: 12,
          padding: '10px 0',
          borderBottom: '1px solid var(--dsh-border, rgba(128,128,128,0.18))',
        },
      }, [
        h('div', {
          key: 'label',
          style: { width: 96, flex: 'none', fontSize: 12, opacity: 0.55 },
        }, label),
        h('div', {
          key: 'value',
          style: {
            flex: 1,
            fontSize: 12,
            fontFamily: mono ? 'ui-monospace, SFMono-Regular, Menlo, monospace' : 'inherit',
            wordBreak: 'break-all',
            userSelect: 'all',
          },
        }, value === undefined || value === null || value === '' ? '—' : String(value)),
        copyable && value ? h(CopyButton, { key: 'copy', value, t }) : null,
      ].filter(Boolean))
    }

    function Section({ title, subtitle, action, children }) {
      return h('section', { style: { marginBottom: 30 } }, [
        h('div', {
          key: 'head',
          style: { display: 'flex', alignItems: 'baseline', gap: 10, marginBottom: 4 },
        }, [
          h('h2', { key: 't', style: { fontSize: 13, fontWeight: 600, margin: 0 } }, title),
          subtitle ? h('span', { key: 's', style: { fontSize: 11, opacity: 0.5 } }, subtitle) : null,
          h('span', { key: 'g', style: { flex: 1 } }),
          action ?? null,
        ].filter(Boolean)),
        children,
      ])
    }

    function DeviceRow({ device }) {
      return h('div', {
        style: {
          display: 'flex',
          alignItems: 'center',
          gap: 10,
          padding: '10px 0',
          borderBottom: '1px solid var(--dsh-border, rgba(128,128,128,0.18))',
        },
      }, [
        h('span', {
          key: 'dot',
          style: { width: 7, height: 7, borderRadius: '50%', background: '#35c26a', flex: 'none' },
        }),
        h('span', { key: 'n', style: { fontSize: 12, flex: 1 } }, device.name ?? device.deviceId),
        h('span', { key: 'p', style: { fontSize: 11, opacity: 0.5 } }, device.platform ?? ''),
      ])
    }

    /** The panel body, rendered in the main area. */
    function MobileBridgePanel({ t }) {
      const [state, setState] = React.useState(null)
      const [error, setError] = React.useState(null)

      React.useEffect(() => {
        let cancelled = false
        const load = async () => {
          try {
            const next = await fetchPanelState()
            if (cancelled) return
            setState(next)
            setError(null)
          } catch (failure) {
            if (!cancelled) setError(failure?.message ?? String(failure))
          }
        }
        void load()
        // A device pairing from a phone is not latency-sensitive, and this panel
        // only reports state, so polling keeps it simple and disposable.
        const timer = setInterval(load, 5000)
        return () => {
          cancelled = true
          clearInterval(timer)
        }
      }, [])

      if (error !== null) {
        return h('div', { style: { padding: '28px 32px', fontSize: 13, opacity: 0.7 } }, [
          h('p', { key: 'm', style: { margin: '0 0 8px' } }, fill(t('loadFailed'), { reason: error })),
          h('p', { key: 'h', style: { margin: 0, fontSize: 12, opacity: 0.7 } },
            t('loadFailedHint')),
        ])
      }
      if (state === null) {
        return h('div', { style: { padding: '28px 32px', fontSize: 13, opacity: 0.6 } }, t('loading'))
      }

      // Prefer the address this machine recommends; a Tailscale peer is usually
      // the one that keeps working away from home.
      const preferred = state.host?.candidates?.find(
        (candidate) => candidate.address === state.host?.preferredAddress,
      ) ?? state.host?.candidates?.[0]
      const address = preferred ? preferred.address : t('unknownAddress')
      const others = (state.host?.candidates ?? [])
        .filter((candidate) => candidate.address !== preferred?.address)
        .map((candidate) => `${candidate.address} (${candidate.kind})`)
      const paired = state.pairedDevices ?? []

      return h('div', {
        style: { padding: '28px 32px', maxWidth: 760, fontSize: 13, lineHeight: 1.65 },
      }, [
        h('header', { key: 'h', style: { marginBottom: 26 } }, [
          h('h1', { key: 't', style: { fontSize: 19, fontWeight: 650, margin: '0 0 4px' } }, t('heading')),
          h('p', { key: 'd', style: { margin: 0, fontSize: 12, opacity: 0.55 } },
            t('tagline')),
        ]),

        h(Section, { key: 'pair', title: t('pairingSection'), subtitle: t('pairingHint') }, [
          h('div', { key: 'f' }, [
            h(Field, { key: 'a', t, label: t('fieldAddress'), value: address, copyable: true }),
            h(Field, { key: 'p', t, label: t('fieldPort'), value: state.port }),
            h(Field, { key: 't', t, label: t('fieldToken'), value: state.token, copyable: true }),
            h(Field, { key: 'c', t, label: t('fieldConfig'), value: state.configPath }),
          ]),
          others.length > 0
            ? h('p', { key: 'o', style: { fontSize: 11, opacity: 0.5, marginTop: 8 } },
              fill(t('otherAddresses'), { addresses: others.join('  ·  ') }))
            : null,
        ].filter(Boolean)),

        h(Section, {
          key: 'devices',
          title: t('devicesSection'),
          subtitle: paired.length === 0 ? t('devicesNone') : fill(t('devicesCount'), { count: paired.length }),
        }, [
          paired.length === 0
            ? h('p', { key: 'e', style: { fontSize: 12, opacity: 0.5, margin: 0 } },
              t('devicesEmpty'))
            : h('div', { key: 'l' }, paired.map((device) =>
              h(DeviceRow, { key: device.deviceId, device }))),
        ]),

        h(Section, { key: 'host', title: t('hostSection') }, [
          h('div', { key: 'f' }, [
            h(Field, { key: 'n', t, label: t('fieldName'), value: state.device?.name, mono: false }),
            h(Field, { key: 'i', t, label: t('fieldDeviceId'), value: state.device?.deviceId }),
            h(Field, { key: 'd', t, label: t('fieldHarness'), value: state.dsh?.version }),
            h(Field, { key: 'b', t, label: t('fieldBridge'), value: state.bridge?.version }),
            h(Field, {
              key: 's',
              label: t('fieldDiscovery'),
              value: state.discovery?.enabled
                ? fill(t('discoveryOn'), { port: state.discovery.port })
                : t('discoveryOff'),
              mono: false,
            }),
          ]),
        ]),
      ])
    }

    return {
      inject: ['slots', 'locale'],
      apply(ctx) {
        // Dictionaries are registered once for the panel's lifetime and disposed
        // with the plugin.
        ctx.effect(() => ctx.locale.register(NS, ZH, EN), 'dsh-mobile-bridge: dictionaries')
        const t = ctx.locale.bind(NS)

        // A global panel is one registration: the `main` keyed slot carries the
        // body, and the sidebar derives its row and More-menu entry from this
        // registry. Registering into `sidebar.panellist` as well would add a
        // second, empty row.
        ctx.slots.inject('main', () => ctx.slots.register({
          name: 'main',
          key: 'mobile-bridge',
          label: () => t('panelTitle'),
          order: 90,
        }, function Panel(props) {
          // The slot hands a component its own props; the translator is closed
          // over here so the body does not need to look it up again.
          return h(MobileBridgePanel, { ...props, t })
        }))
      },
    }
  },
})