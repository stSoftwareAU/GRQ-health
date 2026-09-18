// Per-host health data loading (Issue #213).
//
// A heartbeat used to rewrite the whole fleet-wide index.json (~34 KB) to
// change a few fields of one host. run.sh now writes docs/host-status/<HOST>.json
// (~2 KB) plus a small manifest, so a heartbeat commits one small file.
//
// Hosts run their own checkout of run.sh — and on a multi-user host each unix
// user runs their own — so the fleet migrates one user at a time. This loader
// therefore reads BOTH sources and merges them: the legacy docs/index.json
// carries users and hosts that have not updated yet, and a per-host document
// wins field by field, with the `users` maps merged per user on the newest
// heartbeat so a user still writing to the legacy file is never dropped.
//
// Shared by dashboard.js (index.html), simple.html and sw.js. Plain script, no
// module syntax, so it loads with a <script src> tag and with importScripts().
(function (self) {
    'use strict';

    var HOST_STATUS_DIR = './host-status';
    var MANIFEST_URL = HOST_STATUS_DIR + '/index.json';
    var LEGACY_URL = './index.json';

    // A manifest entry names a file under docs/host-status/. It is data written
    // by whichever host ran last, so validate it as untrusted input: a bare
    // filename component, nothing that can climb out of the directory or carry
    // a query string. Kept in step with host_slug() in run.sh, which is what
    // produces these names.
    var SAFE_HOST_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;

    function isSafeHostName(name) {
        return typeof name === 'string' &&
            SAFE_HOST_NAME.test(name) &&
            name.indexOf('..') === -1;
    }

    function bust(url, timestamp) {
        return url + '?t=' + encodeURIComponent(timestamp);
    }

    function isObject(value) {
        return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
    }

    // Host names come from untrusted JSON, so collect them on a prototype-less
    // map: a host called "__proto__" then adds an entry instead of mutating
    // Object.prototype.
    function emptyMap() {
        return Object.create(null);
    }

    function copyInto(target, source) {
        if (!isObject(source)) {
            return target;
        }
        Object.keys(source).forEach(function (key) {
            target[key] = source[key];
        });
        return target;
    }

    function heartbeatOf(entry) {
        return (isObject(entry) && Number(entry.heart_beat_ts)) || 0;
    }

    function numberOf(entry, field) {
        return (isObject(entry) && Number(entry[field])) || 0;
    }

    // Union of both users maps; for a user in both, the newer heartbeat wins.
    // That is what keeps a user still writing to the legacy file visible while
    // another user on the same host has already migrated.
    function mergeUsers(legacyUsers, docUsers) {
        var merged = emptyMap();
        copyInto(merged, legacyUsers);
        if (isObject(docUsers)) {
            Object.keys(docUsers).forEach(function (username) {
                var existing = merged[username];
                if (!existing || heartbeatOf(docUsers[username]) >= heartbeatOf(existing)) {
                    merged[username] = docUsers[username];
                }
            });
        }
        return merged;
    }

    // Recompute the host-level roll-ups run.sh derives from the users map, so
    // a merged host reports the same aggregates it would if one writer had
    // produced the whole document.
    function applyUserAggregates(host) {
        var usernames = Object.keys(host.users);
        if (usernames.length === 0) {
            return host;
        }
        var heartbeats = usernames.map(function (username) {
            return heartbeatOf(host.users[username]);
        });
        var failing = usernames.filter(function (username) {
            return numberOf(host.users[username], 'exception_count') > 0;
        });

        host.user_count = usernames.length;
        host.worst_user_heart_beat_ts = Math.min.apply(null, heartbeats);
        host.best_user_heart_beat_ts = Math.max.apply(null, heartbeats);
        host.heart_beat_ts = host.best_user_heart_beat_ts;
        host.exception_count = usernames.reduce(function (total, username) {
            return total + numberOf(host.users[username], 'exception_count');
        }, 0);
        host.reporting_warning_count = usernames.reduce(function (total, username) {
            return total + numberOf(host.users[username], 'reporting_warning_count');
        }, 0);
        host.exception_summary = host.exception_count > 0
            ? host.exception_count + ' errors across ' + host.user_count + ' user(s) (' +
                failing.map(function (username) {
                    return username + ': ' + (host.users[username].exception_summary || '');
                }).join('; ') + ')'
            : 'No errors found';
        return host;
    }

    // One host: the per-host document wins field by field, but the users maps
    // are merged so neither writer's heartbeats are lost mid-migration.
    function mergeHostEntry(legacyEntry, doc) {
        var merged = copyInto(emptyMap(), legacyEntry);
        copyInto(merged, doc);
        if (!isObject(legacyEntry) || !isObject(legacyEntry.users)) {
            return merged;
        }
        merged.users = mergeUsers(legacyEntry.users, isObject(doc) ? doc.users : null);
        return applyUserAggregates(merged);
    }

    function mergeHostStatus(legacy, perHost) {
        var merged = emptyMap();
        copyInto(merged, legacy);
        if (isObject(perHost)) {
            Object.keys(perHost).forEach(function (hostname) {
                merged[hostname] = mergeHostEntry(merged[hostname], perHost[hostname]);
            });
        }
        return merged;
    }

    async function fetchJson(fetchFn, url) {
        var response = await fetchFn(url);
        if (!response || !response.ok) {
            var failure = new Error('HTTP ' + ((response && response.status) || 'error') + ' for ' + url);
            failure.status = (response && response.status) || 0;
            throw failure;
        }
        return await response.json();
    }

    // Fetch the manifest and every per-host document it lists.
    // Returns { docs, listed, found } — a failure is always reported through
    // `errors`, never swallowed, but the hosts that did load are still returned.
    async function fetchPerHost(fetchFn, timestamp, errors) {
        var manifest;
        try {
            manifest = await fetchJson(fetchFn, bust(MANIFEST_URL, timestamp));
        } catch (error) {
            // 404 is the expected pre-migration state: no host has written a
            // document yet. Anything else is a real fault and must be seen.
            if (error.status !== 404) {
                errors.push('Failed to load the host-status manifest: ' + error.message);
            }
            return { docs: emptyMap(), listed: 0, found: false };
        }

        if (!isObject(manifest) || !Array.isArray(manifest.hosts)) {
            errors.push('Malformed host-status manifest: expected a "hosts" array');
            return { docs: emptyMap(), listed: 0, found: false };
        }

        var safeNames = [];
        manifest.hosts.forEach(function (name) {
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

        var docs = emptyMap();
        settled.forEach(function (entry) {
            if (!entry || !isObject(entry.doc)) {
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
        if (legacyError && perHost.listed === 0) {
            throw new Error('No health data available: ' + legacyError.message + ' and the host-status manifest lists no hosts');
        }
        if (legacyError && legacyError.status !== 404) {
            // The fleet file is still expected until the migration completes,
            // so a failure that is not "gone" means hosts may be missing.
            errors.push('Failed to load ' + LEGACY_URL + ': ' + legacyError.message +
                ' — hosts that have not migrated are missing');
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
