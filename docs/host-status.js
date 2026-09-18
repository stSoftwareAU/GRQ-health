// Per-host health data loading (Issue #213).
//
// A heartbeat used to rewrite the whole fleet-wide index.json (~34 KB) to
// change a few fields of one host. run.sh now writes docs/host-status/<HOST>.json
// (~2 KB) plus a small manifest, so a heartbeat commits one small file.
//
// Hosts run their own checkout of run.sh, so the fleet migrates one host at a
// time. This loader therefore reads BOTH sources and merges them: the legacy
// docs/index.json provides hosts that have not updated yet, and a per-host
// document — written by a host that has — always wins for that host.
//
// Shared by dashboard.js (index.html) and simple.html. Plain script, no module
// syntax, so it loads with a <script src> tag on both pages.
(function (self) {
    'use strict';

    var HOST_STATUS_DIR = './host-status';
    var MANIFEST_URL = HOST_STATUS_DIR + '/index.json';
    var LEGACY_URL = './index.json';

    // A manifest entry names a file under docs/host-status/. It is data written
    // by whichever host ran last, so validate it as untrusted input: a bare
    // filename component, nothing that can climb out of the directory or carry
    // a query string.
    var SAFE_HOST_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;

    function isSafeHostName(name) {
        return typeof name === 'string' &&
            SAFE_HOST_NAME.test(name) &&
            name.indexOf('..') === -1;
    }

    function bust(url, timestamp) {
        return url + '?t=' + encodeURIComponent(timestamp);
    }

    // Per-host documents override the legacy fleet-wide entry for the same host.
    function mergeHostStatus(legacy, perHost) {
        var merged = {};
        var hostname;
        if (legacy && typeof legacy === 'object') {
            for (hostname in legacy) {
                if (Object.prototype.hasOwnProperty.call(legacy, hostname)) {
                    merged[hostname] = legacy[hostname];
                }
            }
        }
        if (perHost && typeof perHost === 'object') {
            for (hostname in perHost) {
                if (Object.prototype.hasOwnProperty.call(perHost, hostname)) {
                    merged[hostname] = perHost[hostname];
                }
            }
        }
        return merged;
    }

    async function fetchJson(fetchFn, url) {
        var response = await fetchFn(url);
        if (!response || !response.ok) {
            throw new Error('HTTP ' + ((response && response.status) || 'error') + ' for ' + url);
        }
        return await response.json();
    }

    // Fetch the manifest and every per-host document it lists.
    // Returns { docs, listed, errors } — a failed document is reported, never
    // swallowed, but the hosts that did load are still returned.
    async function fetchPerHost(fetchFn, timestamp, errors) {
        var manifest;
        try {
            manifest = await fetchJson(fetchFn, bust(MANIFEST_URL, timestamp));
        } catch (error) {
            // No manifest yet: the whole fleet is still pre-migration.
            return { docs: {}, listed: 0, found: false };
        }

        var names = (manifest && Array.isArray(manifest.hosts)) ? manifest.hosts : [];
        var safeNames = [];
        names.forEach(function (name) {
            if (isSafeHostName(name)) {
                safeNames.push(name);
            } else {
                errors.push('Rejected unsafe host-status manifest entry: ' + JSON.stringify(name));
            }
        });

        var settled = await Promise.all(safeNames.map(function (name) {
            return fetchJson(fetchFn, bust(HOST_STATUS_DIR + '/' + name + '.json', timestamp))
                .then(function (doc) { return { name: name, doc: doc }; })
                .catch(function (error) {
                    errors.push('Failed to load host document for ' + name + ': ' + error.message);
                    return null;
                });
        }));

        var docs = {};
        settled.forEach(function (entry) {
            if (!entry || !entry.doc || typeof entry.doc !== 'object') {
                return;
            }
            // The document names its own host; the filename is only a slug of it.
            var hostname = (typeof entry.doc.host === 'string' && entry.doc.host) ? entry.doc.host : entry.name;
            docs[hostname] = entry.doc;
        });

        return { docs: docs, listed: safeNames.length, found: true };
    }

    /**
     * Load fleet health data from the per-host documents and the legacy
     * fleet-wide index.json, merged.
     *
     * @param {Function} fetchFn fetch implementation (injected so it is testable)
     * @param {number|string} timestamp cache buster
     * @returns {Promise<{data: Object, sources: Object, errors: string[]}>}
     * @throws {Error} when neither source yields data — a blank fleet must fail
     *                 loud rather than render as "no hosts".
     */
    async function loadHostStatus(fetchFn, timestamp) {
        var errors = [];
        var perHost = await fetchPerHost(fetchFn, timestamp, errors);

        var legacy = null;
        var legacyError = null;
        try {
            legacy = await fetchJson(fetchFn, bust(LEGACY_URL, timestamp));
        } catch (error) {
            legacyError = error;
        }

        if (!legacy && !perHost.found) {
            // Nothing loaded at all: surface the legacy failure, which is the
            // one that matters for a fleet that has not migrated.
            throw legacyError || new Error('No health data available from ' + LEGACY_URL + ' or ' + MANIFEST_URL);
        }
        if (legacyError && perHost.found && perHost.listed === 0) {
            throw new Error('No health data available: ' + legacyError.message + ' and the host-status manifest lists no hosts');
        }

        return {
            data: mergeHostStatus(legacy, perHost.docs),
            sources: {
                manifest: perHost.found,
                perHost: Object.keys(perHost.docs).length,
                legacy: legacy !== null
            },
            errors: errors
        };
    }

    self.GRQHostStatus = {
        HOST_STATUS_DIR: HOST_STATUS_DIR,
        MANIFEST_URL: MANIFEST_URL,
        LEGACY_URL: LEGACY_URL,
        isSafeHostName: isSafeHostName,
        mergeHostStatus: mergeHostStatus,
        loadHostStatus: loadHostStatus
    };
})(typeof self !== 'undefined' ? self : this);
