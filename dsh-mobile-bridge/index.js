/**
 * dsh-mobile-bridge entry point.
 *
 * The Loader caches the package's module generation for the lifetime of the
 * process, so edits to the implementation would otherwise need a Harness
 * restart. This entry re-imports the implementation with its modification time
 * as the module URL version: an unchanged file reuses the cached generation,
 * and an edited file loads fresh on the next activation.
 *
 * @module dsh-mobile-bridge
 */

import { statSync } from 'node:fs'

/** Loader id for the single row this bundle inserts. */
export const name = 'dsh-mobile-bridge'

/** The Host Session API is the only hard dependency; everything else is optional. */
export const inject = ['sessionController']

/** Absolute URL of the implementation module. */
const IMPLEMENTATION = new URL('./bridge.js', import.meta.url)

/**
 * Build the versioned implementation URL.
 * @returns the module URL carrying the file's modification time.
 */
function versionedUrl() {
  try {
    return `${IMPLEMENTATION.href}?v=${statSync(IMPLEMENTATION).mtimeMs}`
  } catch {
    return IMPLEMENTATION.href
  }
}

/**
 * Start the LAN bridge for this Harness process.
 * @param ctx - the Host plugin context, carrying `sessionController`.
 * @param config - the Loader row's config object.
 */
export function apply(ctx, config = {}) {
  ctx.effect(() => {
    let disposed = false
    let stop = () => {}
    const loading = import(versionedUrl()).then(
      (implementation) => {
        if (disposed) return
        stop = implementation.startBridge(ctx, config) ?? (() => {})
      },
      (error) => {
        if (disposed) return
        ctx.logger.error(`dsh-mobile-bridge: could not load the implementation: ${error?.message ?? error}`)
      },
    )
    return () => {
      disposed = true
      void loading.then(() => {
        stop()
      })
    }
  }, 'dsh-mobile-bridge: implementation')
}