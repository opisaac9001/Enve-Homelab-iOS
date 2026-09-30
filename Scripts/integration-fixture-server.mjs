// Local protocol fixtures for integration tests. Each route checks the vendor's auth mechanism and
// returns documented response shapes. No dependencies; nothing leaves 127.0.0.1.
// Usage: node integration-fixture-server.mjs <httpPort> <httpsPort> <certPath> <keyPath>
import { createServer } from 'node:http';
import { createServer as createTLSServer } from 'node:https';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

const [httpPort, httpsPort, certPath, keyPath] = process.argv.slice(2);
const log = [];
const record = (entry) => log.push(entry);
let proxmoxPolls = 0;

const json = (res, status, body, headers = {}) => {
  res.writeHead(status, { 'Content-Type': 'application/json', ...headers });
  res.end(JSON.stringify(body));
};
const text = (res, status, body, headers = {}) => {
  res.writeHead(status, { 'Content-Type': 'text/plain', ...headers });
  res.end(body);
};
const readBody = (req) => new Promise((resolve) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => resolve(Buffer.concat(chunks).toString()));
});

async function arr(req, res, url) {
  if (req.headers['x-api-key'] !== 'arr-key') return json(res, 401, { error: 'Unauthorized' });
  const [, app] = url.pathname.match(/^\/(radarr|sonarr|lidarr)\//);
  const p = url.pathname.replace(/^\/(radarr|sonarr)\/api\/v3|^\/lidarr\/api\/v1/, '');
  if (p === '/calendar') {
    const start = Date.parse(url.searchParams.get('start')), end = Date.parse(url.searchParams.get('end'));
    const unmonitored = url.searchParams.get('unmonitored');
    if (Number.isNaN(start) || Number.isNaN(end) || !['true', 'false'].includes(unmonitored)) return json(res, 400, { message: 'start, end and unmonitored expected' });
    const inside = new Date(start + 86_400_000).toISOString(), before = new Date(start - 86_400_000).toISOString();
    if (app === 'radarr') return json(res, 200, [{ id: 1, title: 'Sintel', year: 2010, inCinemas: before, digitalRelease: inside, hasFile: false, monitored: true },
      ...(unmonitored === 'true' ? [{ id: 2, title: 'Elephants Dream', year: 2006, digitalRelease: inside, hasFile: false, monitored: false }] : [])]);
    if (app === 'sonarr') {
      if (url.searchParams.get('includeSeries') !== 'true') return json(res, 400, { message: 'includeSeries expected' });
      return json(res, 200, [{ id: 2, title: 'Pilot', seasonNumber: 1, episodeNumber: 1, airDateUtc: inside, hasFile: true, series: { title: 'Pioneer One' } }]);
    }
    if (url.searchParams.get('includeArtist') !== 'true') return json(res, 400, { message: 'includeArtist expected' });
    return json(res, 200, [{ id: 3, title: 'Big Buck Bunny OST', releaseDate: inside, artist: { artistName: 'Blender' }, statistics: { trackFileCount: 0 } }]);
  }
  if (p === '/system/task') return json(res, 200, [
    { id: 1, name: 'Backup', taskName: 'Backup', interval: 10080, lastExecution: '2026-09-27T02:00:00Z', lastStartTime: '2026-09-27T02:00:00Z', nextExecution: '2026-10-04T02:00:00Z', lastDuration: '00:00:03.2100000' },
    { id: 2, name: 'RSS Sync', taskName: 'RssSync', interval: 15, lastExecution: '2026-09-29T09:45:00Z', nextExecution: '2026-09-29T10:00:00Z', lastDuration: '00:00:01.5000000' }]);
  if (p === '/log') {
    if (url.searchParams.get('level') !== 'warn' || url.searchParams.get('sortDirection') !== 'descending') return json(res, 400, { message: 'level and sortDirection expected' });
    return json(res, 200, { page: 1, pageSize: 20, sortKey: 'time', sortDirection: 'descending', totalRecords: 57, records: [
      { id: 9, time: '2026-09-29T09:30:00Z', level: 'warn', logger: 'DownloadClientCheck', message: 'Unable to communicate with SABnzbd' },
      { id: 8, time: '2026-09-29T08:00:00Z', level: 'error', logger: 'ImportListSync', message: 'HTTP 401', exception: 'HttpException', exceptionType: 'HttpException' },
      { id: 7, time: '2026-09-29T07:00:00Z', level: 'info', logger: 'Stray', message: 'Should be filtered' }] });
  }
  if (p === '/update') return json(res, 200, [
    { version: '5.27.0.10202', branch: 'master', releaseDate: '2026-09-28T00:00:00Z', installed: false, installable: true, latest: true, changes: { new: ['Faster queue'], fixed: ['Sorting'] } },
    { version: '5.26.2.10099', branch: 'master', releaseDate: '2026-08-01T00:00:00Z', installed: true, installable: false, latest: false, changes: null }]);
  if (p === '/system/backup') return json(res, 200, [{ id: 1, name: 'radarr_backup_v5.26.2_2026.09.27.zip', path: '/backup/scheduled/x.zip', type: 'scheduled', size: 4812000, time: '2026-09-27T02:00:03Z' }]);
  if (p === '/wanted/missing') {
    if (url.searchParams.get('monitored') !== 'true' || url.searchParams.get('pageSize') === null) return json(res, 400, { message: 'monitored and pageSize expected' });
    if (app === 'radarr') return json(res, 200, { page: 1, pageSize: 20, totalRecords: 7, records: [
      { id: 3, title: 'Cosmos Laundromat', year: 2015, inCinemas: '2015-08-10T00:00:00Z', digitalRelease: '2015-09-01T00:00:00Z', physicalRelease: '2099-01-01T00:00:00Z', hasFile: false, monitored: true },
      { id: 4, title: 'Tears of Steel', year: 2012, inCinemas: '2012-09-26T00:00:00Z', hasFile: false, monitored: true }] });
    if (app === 'sonarr') {
      if (url.searchParams.get('includeSeries') !== 'true') return json(res, 400, { message: 'includeSeries expected' });
      return json(res, 200, { page: 1, pageSize: 20, totalRecords: 1, records: [{ id: 5, title: 'Sermon', seasonNumber: 1, episodeNumber: 4, airDateUtc: '2010-07-01T02:00:00Z', hasFile: false, monitored: true, series: { title: 'Pioneer One' } }] });
    }
    return json(res, 200, { page: 1, pageSize: 20, totalRecords: 0, records: [] });
  }
  if (p === '/system/status') return json(res, 200, { appName: 'Radarr', instanceName: 'Radarr', version: '5.26.2.10099' });
  if (p === '/health') return json(res, 200, [{ source: 'DownloadClientCheck', type: 'warning', message: 'Unable to communicate with SABnzbd', wikiUrl: 'https://wiki.servarr.com' }]);
  if (p === '/diskspace') return json(res, 200, [{ id: 1, path: '/data', label: 'data', freeSpace: 400, totalSpace: 1000 }]);
  if (p === '/queue') {
    if (url.searchParams.get('includeMovie') !== 'true') return json(res, 400, { message: 'includeMovie expected' });
    return json(res, 200, { page: 1, pageSize: 100, totalRecords: 1, records: [{ id: 7, movie: { title: 'Sintel', year: 2010 }, title: 'Sintel.2010.1080p', status: 'downloading', trackedDownloadStatus: 'ok', trackedDownloadState: 'downloading', size: 100, sizeleft: 40, timeleft: '00:01:00', statusMessages: [], downloadClient: 'qBittorrent', protocol: 'torrent' }] });
  }
  if (p === '/command' && req.method === 'POST') { record(`arr command ${JSON.parse(await readBody(req)).name}`); return json(res, 201, { id: 1, name: 'RssSync', status: 'queued' }); }
  if (p === '/queue/7' && req.method === 'DELETE') { record(`arr delete 7 removeFromClient=${url.searchParams.get('removeFromClient')} blocklist=${url.searchParams.get('blocklist')}`); return json(res, 200, {}); }
  return json(res, 404, { message: 'NotFound' });
}

async function qbittorrent(req, res, url) {
  const p = url.pathname.replace('/qbt/api/v2', '');
  const host = `http://${req.headers.host}`;
  if (p === '/auth/login') {
    if (!(req.headers.referer ?? '').startsWith(host)) return text(res, 401, 'Unauthorized');
    const form = new URLSearchParams(await readBody(req));
    if (form.get('username') === 'admin' && form.get('password') === 'p@ss&word') return text(res, 200, 'Ok.', { 'Set-Cookie': 'SID=fixture-sid; HttpOnly; path=/' });
    return text(res, 200, 'Fails.');
  }
  if (!(req.headers.cookie ?? '').includes('SID=fixture-sid')) return text(res, 403, 'Forbidden');
  if (p === '/app/webapiVersion') return text(res, 200, '2.11.2');
  if (p === '/app/version') return text(res, 200, 'v5.1.2');
  if (p === '/transfer/info') return json(res, 200, { dl_info_speed: 2048, up_info_speed: 512, connection_status: 'connected' });
  if (p === '/torrents/info') return json(res, 200, [{ hash: 'abc123', name: 'debian.iso', size: 100, progress: 0.5, dlspeed: 2048, upspeed: 0, eta: 60, state: 'downloading', category: 'iso', amount_left: 50 }]);
  if (p === '/torrents/trackers') {
    if (url.searchParams.get('hash') !== 'abc123') return text(res, 404, 'Not Found');
    return json(res, 200, [
      { url: '** [DHT] **', status: 0, tier: -1, num_peers: 12, num_seeds: 0, num_leeches: 0, num_downloaded: 0, msg: '' },
      { url: 'https://tracker.example.org/announce/0123456789abcdef-passkey', status: 2, tier: 0, num_peers: 7, num_seeds: 42, num_leeches: 3, num_downloaded: 900, msg: '' },
      { url: 'udp://backup.example.net:6969/announce', status: 4, tier: 1, num_peers: -1, num_seeds: -1, num_leeches: -1, num_downloaded: -1, msg: 'Connection timed out' }]);
  }
  if (p === '/torrents/recheck') { const form = new URLSearchParams(await readBody(req)); record(`qbt recheck ${form.get('hashes')}`); return text(res, 200, ''); }
  if (p === '/torrents/stop' || p === '/torrents/start' || p === '/torrents/delete') {
    const form = new URLSearchParams(await readBody(req));
    record(`qbt ${p.split('/').pop()} ${form.get('hashes')}${form.has('deleteFiles') ? ` deleteFiles=${form.get('deleteFiles')}` : ''}`);
    return text(res, 200, '');
  }
  return text(res, 404, 'Not Found');
}

async function transmission(req, res) {
  if (req.headers.authorization !== `Basic ${Buffer.from('rpc:secret').toString('base64')}`) return text(res, 401, 'Unauthorized');
  if (req.headers['x-transmission-session-id'] !== 'session-42') return text(res, 409, 'Conflict', { 'X-Transmission-Session-Id': 'session-42' });
  const body = JSON.parse(await readBody(req));
  switch (body.method) {
    case 'session-get': return json(res, 200, { result: 'success', arguments: { version: '4.0.6 (38c164933e)' } });
    case 'session-stats': return json(res, 200, { result: 'success', arguments: { downloadSpeed: 1000, uploadSpeed: 10 } });
    case 'torrent-get':
      if ((body.arguments.fields ?? []).includes('trackerStats')) {
        if (JSON.stringify(body.arguments.ids) !== '["def456"]') return json(res, 200, { result: 'success', arguments: { torrents: [] } });
        return json(res, 200, { result: 'success', arguments: { torrents: [{ trackerStats: [
          { id: 0, announce: 'https://tracker.example.org/announce?passkey=secret', host: 'https://tracker.example.org:443', announceState: 1, hasAnnounced: true, lastAnnounceSucceeded: true, lastAnnounceResult: 'Success', seederCount: 30, leecherCount: 2 },
          { id: 1, announce: 'udp://down.example.net:6969/announce', host: 'udp://down.example.net:6969', announceState: 1, hasAnnounced: true, lastAnnounceSucceeded: false, lastAnnounceResult: 'Could not connect to tracker', seederCount: -1, leecherCount: -1 },
          { id: 2, announce: 'udp://new.example.com:80/announce', host: 'udp://new.example.com:80', announceState: 2, hasAnnounced: false, lastAnnounceSucceeded: false, lastAnnounceResult: '', seederCount: -1, leecherCount: -1 }] }] } });
      }
      return json(res, 200, { result: 'success', arguments: { torrents: [{ id: 1, hashString: 'def456', name: 'ubuntu.iso', status: 6, percentDone: 1, totalSize: 10, leftUntilDone: 0, rateDownload: 0, rateUpload: 10, eta: -1, error: 0, errorString: '', labels: [] }] } });
    case 'torrent-verify': record(`transmission verify ${body.arguments.ids.join(',')}`); return json(res, 200, { result: 'success', arguments: {} });
    case 'torrent-remove': record(`transmission remove ${body.arguments.ids.join(',')} delete=${body.arguments['delete-local-data']}`); return json(res, 200, { result: 'success', arguments: {} });
    default: return json(res, 200, { result: `unsupported method ${body.method}` });
  }
}

function sabnzbd(req, res, url) {
  if (url.searchParams.get('apikey') !== 'sab-key') return json(res, 200, { status: false, error: 'API Key Incorrect' });
  const mode = url.searchParams.get('mode');
  if (mode === 'queue' && !url.searchParams.get('name')) return json(res, 200, { queue: { status: 'Downloading', paused: false, kbpersec: '1024.0', version: '4.5.3', slots: [{ nzo_id: 'SABnzbd_nzo_1', filename: 'Example', status: 'Downloading', percentage: '10', mb: '100', mbleft: '90', timeleft: '0:01:30', cat: '*' }] } });
  if (mode === 'queue') { record(`sab ${url.searchParams.get('name')} ${url.searchParams.get('value')} del_files=${url.searchParams.get('del_files') ?? ''}`); return json(res, 200, { status: true, nzo_ids: [url.searchParams.get('value')] }); }
  if (mode === 'pause' || mode === 'resume') { record(`sab ${mode}`); return json(res, 200, { status: true }); }
  return json(res, 200, { status: false, error: 'not implemented' });
}

const jellyfinSession = { Id: 's1', UserName: 'alex', Client: 'Jellyfin Web', DeviceName: 'Firefox', SupportsRemoteControl: true,
  NowPlayingItem: { Name: 'Sintel', Type: 'Movie', RunTimeTicks: 8880000000, MediaStreams: [
    { Type: 'Video', Index: 0, DisplayTitle: '1080p H264 SDR', Codec: 'h264', Path: '/media/secret/path.mkv' },
    { Type: 'Audio', Index: 1, DisplayTitle: 'English - AAC - Stereo', Codec: 'aac', Language: 'eng' },
    { Type: 'Audio', Index: 2, DisplayTitle: 'Commentary - AAC - Stereo', Codec: 'aac' },
    { Type: 'Subtitle', Index: 3, DisplayTitle: 'English - SRT', Codec: 'srt', DeliveryUrl: '/Videos/x/Subtitles/3/Stream.srt?api_key=leak' }] },
  PlayState: { PositionTicks: 4440000000, IsPaused: false, PlayMethod: 'DirectPlay', AudioStreamIndex: 1, SubtitleStreamIndex: -1 } };

async function mediaBrowser(req, res, url, flavor) {
  const authorized = flavor === 'jf'
    ? /Token="jf-key"/.test(req.headers.authorization ?? '')
    : req.headers['x-emby-token'] === 'emby-key';
  if (!authorized) return text(res, 401, '');
  const p = url.pathname.replace(flavor === 'jf' ? '/jf' : '/emby', '');
  if (p === '/Items/Counts') return json(res, 200, { MovieCount: 3, SeriesCount: 1, EpisodeCount: 12, ArtistCount: 0, ProgramCount: 0, TrailerCount: 0, SongCount: 0, AlbumCount: 0, MusicVideoCount: 0, BoxSetCount: 1, BookCount: 0, ItemCount: 17 });
  if (p === '/Plugins' && flavor === 'jf') return json(res, 200, [{ Name: 'Open Subtitles', Version: '20.0.0.0', Id: 'a', CanUninstall: true, HasImage: false, Status: 'Malfunctioned' }, { Name: 'Playback Reporting', Version: '16.0.0.0', Id: 'b', CanUninstall: true, HasImage: false, Status: 'Active' }]);
  if (p === '/Packages/Updates' && flavor === 'emby') {
    const type = url.searchParams.get('PackageType');
    if (type === 'System') return json(res, 200, [{ name: 'Emby Server', versionStr: '4.10.0.40', classification: 'Release' }]);
    if (type === 'UserInstalled') return json(res, 200, [{ name: 'Trakt', versionStr: '4.5.1.0', classification: 'Release' }]);
    return json(res, 400, {});
  }
  if (p === '/System/Logs' && flavor === 'jf') return json(res, 200, [{ Name: 'log_20260928.log', Size: 2048, DateModified: '2026-09-28T23:59:00Z' }, { Name: 'log_20260929.log', Size: 1024, DateModified: '2026-09-29T10:00:00Z' }]);
  if (p === '/System/Logs/Log' && flavor === 'jf') {
    if (url.searchParams.get('name') !== 'log_20260929.log') return text(res, 404, '');
    return text(res, 200, '[10:00:00] [INF] Started\n[10:00:01] [WRN] GET /Items?api_key=deadbeefcafe slow\n[10:00:02] [ERR] Plugin failed\n');
  }
  if (p === '/System/Logs/Query' && flavor === 'emby') return json(res, 200, { Items: [{ Name: 'embyserver.txt', Size: 4096, DateModified: '2026-09-29T10:00:00Z' }], TotalRecordCount: 1 });
  if (p === '/System/Logs/embyserver.txt/Lines' && flavor === 'emby') return json(res, 200, { Items: ['2026-09-29 10:00:00.000 Info App: started', '2026-09-29 10:00:02.000 Error HttpServer: X-Emby-Token=0123456789abcdef rejected'], TotalRecordCount: 2 });
  if (p === '/System/Info') return json(res, 200, { ServerName: flavor === 'jf' ? 'Fixture Jellyfin' : 'Fixture Emby', Version: flavor === 'jf' ? '10.11.0' : '4.9.1.80', HasUpdateAvailable: false, HasPendingRestart: true, CanSelfRestart: true, OperatingSystemDisplayName: 'Linux' });
  if (p === '/Sessions') return json(res, 200, [flavor === 'jf'
    ? { ...jellyfinSession, Capabilities: { SupportedCommands: ['DisplayMessage', 'SetAudioStreamIndex', 'SetSubtitleStreamIndex'] } }
    : { ...jellyfinSession, SupportedCommands: ['DisplayMessage'] }, { Id: 'idle', UserName: 'sam' }]);
  const hiddenParam = flavor === 'jf' ? 'isHidden' : 'IsHidden';
  if (p === '/ScheduledTasks' && req.method === 'GET') {
    if (url.searchParams.get(hiddenParam) !== 'false') return json(res, 400, { message: `${hiddenParam} expected` });
    return json(res, 200, [
      { Id: 'task-scan', Name: 'Scan Media Library', State: 'Running', Category: 'Library', CurrentProgressPercentage: 40, LastExecutionResult: null },
      { Id: 'task-chapters', Name: 'Extract Chapter Images', State: 'Idle', Category: 'Library', LastExecutionResult: { EndTimeUtc: '2026-09-28T02:00:00.0000000Z', Status: 'Failed', ErrorMessage: 'ffmpeg exited with code 1' } },
    ]);
  }
  const task = p.match(/^\/ScheduledTasks\/Running\/([\w-]+)$/);
  if (task) { record(`${flavor} task ${req.method} ${task[1]}`); res.writeHead(204); return res.end(); }
  if (p === '/Devices' && req.method === 'GET') {
    if (flavor === 'emby') return text(res, 403, 'Access denied');
    return json(res, 200, { Items: [{ Id: 'dev-1', Name: 'Living Room', AppName: 'Jellyfin Android TV', AppVersion: '0.18', LastUserName: 'alex', DateLastActivity: '2026-09-29T10:00:00.0000000Z', AccessToken: 'never-decoded-token' }], TotalRecordCount: 1 });
  }
  if (p === '/Devices' && req.method === 'DELETE') { record(`${flavor} remove device ${url.searchParams.get(flavor === 'jf' ? 'id' : 'Id')}`); res.writeHead(204); return res.end(); }
  if (p === '/System/ActivityLog/Entries') {
    if (flavor === 'emby') return text(res, 401, '');
    return json(res, 200, { Items: [{ Id: 7, Name: 'alex is playing Sintel', ShortOverview: 'Firefox', Date: '2026-09-29T10:00:00.0000000Z', Severity: 'Information' },
      { Id: 8, Name: 'Failed login attempt from 192.0.2.4', Date: '2026-09-29T09:00:00.0000000Z', Severity: 'Warning' }], TotalRecordCount: 2 });
  }
  if (p === '/System/Restart' && req.method === 'POST') { record(`${flavor} restart`); res.writeHead(204); return res.end(); }
  if (p === '/Sessions/s1/Message' && req.method === 'POST') {
    const text = flavor === 'jf' ? JSON.parse(await readBody(req)).Text : url.searchParams.get('Text');
    record(`${flavor} message s1 ${text}`); res.writeHead(204); return res.end();
  }
  if (p === '/Sessions/s1/Command' && req.method === 'POST') { const b = JSON.parse(await readBody(req)); record(`${flavor} command s1 ${b.Name} ${b.Arguments.Index}`); res.writeHead(204); return res.end(); }
  const itemRefresh = p.match(/^\/Items\/(\w+)\/Refresh$/);
  if (itemRefresh && req.method === 'POST') { record(`${flavor} refresh item ${itemRefresh[1]} ${[...url.searchParams.keys()].sort().join(',')}`); res.writeHead(204); return res.end(); }
  if (p === '/Library/VirtualFolders' && flavor === 'jf') return json(res, 200, [{ Name: 'Movies', CollectionType: 'movies', ItemId: 'lib1' }]);
  if (p === '/Library/VirtualFolders/Query' && flavor === 'emby') return json(res, 200, { Items: [{ Name: 'Movies', CollectionType: 'movies', Id: 'lib1' }], TotalRecordCount: 1 });
  if (p === '/Items') return json(res, 200, { Items: [{ Id: 'i1', Name: 'Sintel', Type: 'Movie', ProductionYear: 2010, DateCreated: '2025-01-01T00:00:00.0000000Z' }], TotalRecordCount: 1 });
  if (p === '/Users' && flavor === 'jf') return json(res, 200, [{ Id: 'u1', Name: 'alex', LastActivityDate: '2026-09-29T10:00:00.0000000Z', Policy: { IsAdministrator: true, IsDisabled: false } }, { Id: 'u2', Name: 'guest', Policy: { IsAdministrator: false, IsDisabled: true } }]);
  if (p === '/Users/Query' && flavor === 'emby') return json(res, 200, { Items: [{ Id: 'u1', Name: 'alex' }] });
  if ((p === '/UserItems/Resume' && url.searchParams.get('userId') === 'u1') || p === '/Users/u1/Items/Resume') return json(res, 200, { Items: [{ Id: 'r1', Name: 'Sintel', Type: 'Movie', UserData: { PlayedPercentage: 50 } }] });
  const command = p.match(/^\/Sessions\/(\w+)\/Playing\/(\w+)$/);
  if (command && req.method === 'POST') { record(`${flavor} ${command[2]} ${command[1]}`); res.writeHead(204); return res.end(); }
  if (p === '/Library/Refresh' && req.method === 'POST') { record(`${flavor} refresh`); res.writeHead(204); return res.end(); }
  return text(res, 404, '');
}

async function plex(req, res, url) {
  if (req.headers['x-plex-token'] !== 'plex-token') return text(res, 401, '<html>Unauthorized</html>');
  const p = url.pathname.replace(/^\/plex/, '') || '/';
  if (p === '/') return json(res, 200, { MediaContainer: { friendlyName: 'Fixture Plex', version: '1.42.1.10060' } });
  if (p === '/library/sections') return json(res, 200, { MediaContainer: { Directory: [{ key: '1', title: 'Movies', type: 'movie', refreshing: false }] } });
  if (p === '/library/recentlyAdded') return json(res, 200, { MediaContainer: { Metadata: [{ ratingKey: '9', title: 'Sintel', type: 'movie', year: 2010, addedAt: 1700000000 }] } });
  if (p === '/hubs/continueWatching') return json(res, 200, { MediaContainer: { Hub: [{ Metadata: [{ ratingKey: '9', title: 'Sintel', type: 'movie', viewOffset: 10, duration: 20 }] }] } });
  if (p === '/status/sessions') return json(res, 200, { MediaContainer: { Metadata: [{ ratingKey: '9', title: 'Sintel', type: 'movie', viewOffset: 1000, duration: 4000, User: { title: 'alex' }, Player: { title: 'TV', product: 'Plex for Apple TV', state: 'playing' }, Session: { id: 'plex-session', bandwidth: 12000, location: 'lan' },
    Media: [{ selected: true, Part: [{ file: '/data/secret/sintel.mkv', Stream: [{ id: 1, streamType: 1, displayTitle: '1080p (HEVC Main 10)' }, { id: 2, streamType: 2, displayTitle: 'English (EAC3 5.1)', selected: true }, { id: 3, streamType: 3, displayTitle: 'English (SRT)', extendedDisplayTitle: 'English (SRT External)', selected: true }] }] }] }] } });
  if (p === '/updater/status') return json(res, 200, { MediaContainer: { canInstall: false, Release: [{ version: '1.42.2.10156', state: 'notify' }] } });
  if (p === '/butler' && req.method === 'GET') return json(res, 200, { ButlerTasks: { ButlerTask: [{ name: 'BackupDatabase', title: 'Back up database', description: 'Create a backup of the database', enabled: true, interval: 3, scheduleRandomized: false }] } });
  if (p === '/activities' && req.method === 'GET') return json(res, 200, { MediaContainer: { size: 1, Activity: [{ uuid: 'act-1', type: 'library.update.section', title: 'Scanning Movies', subtitle: 'Sintel', progress: 55, cancellable: true }] } });
  if (p === '/status/sessions/history/all') {
    if (url.searchParams.get('sort') !== 'viewedAt:desc') return text(res, 400, 'sort expected');
    return json(res, 200, { MediaContainer: { size: 1, Metadata: [{ ratingKey: '9', title: 'Sintel', type: 'movie', viewedAt: 1790000000, accountID: 1 }] } });
  }
  const plexAction = `${req.method} ${p}`;
  if (['POST /butler/BackupDatabase', 'DELETE /activities/act-1', 'PUT /library/sections/1/analyze', 'PUT /library/sections/1/emptyTrash', 'PUT /library/optimize', 'PUT /library/clean/bundles', 'PUT /updater/check'].includes(plexAction)) {
    record(`plex ${plexAction}`); return text(res, 200, '');
  }
  if (p === '/status/sessions/terminate' && req.method === 'POST') { record(`plex terminate ${url.searchParams.get('sessionId')}`); return text(res, 401, 'Plex Pass required'); }
  const refresh = p.match(/^\/library\/sections\/(\w+)\/refresh$/);
  if (refresh && req.method === 'POST') { record(`plex refresh ${refresh[1]}${url.searchParams.get('force') ? ` force=${url.searchParams.get('force')}` : ''}`); return text(res, 200, ''); }
  return text(res, 404, '');
}

async function proxmox(req, res, url) {
  // A second token stands in for one without Sys.Audit.
  if (req.headers.authorization !== 'PVEAPIToken=ci@pve!homelab=0000-1111' && req.headers.authorization !== 'PVEAPIToken=auditor-less@pve!x=1') return json(res, 401, { data: null });
  const p = decodeURIComponent(url.pathname).replace('/pve/api2/json', '');
  if (p === '/version') return json(res, 200, { data: { version: '9.0.10', release: '9.0', repoid: 'abc' } });
  if (p === '/nodes') return json(res, 200, { data: [{ node: 'pve1', status: 'online', cpu: 0.1, maxcpu: 8, mem: 1, maxmem: 4, uptime: 100 }] });
  if (p === '/cluster/resources' && url.searchParams.get('type') === 'vm') return json(res, 200, { data: [{ id: 'qemu/100', type: 'qemu', node: 'pve1', vmid: 100, name: 'ha', status: 'running' }] });
  if (p === '/cluster/tasks') return json(res, 200, { data: [{ upid: 'UPID:pve1:1', node: 'pve1', type: 'vzdump', id: '100', user: 'root@pam', starttime: 1, endtime: 2, status: 'OK' }] });
  if (p === '/nodes/pve1/status') return json(res, 200, { data: { cpu: 0.12, loadavg: ['0.52', '0.40', '0.33'], uptime: 90000, pveversion: 'pve-manager/9.0.10/abc', kversion: 'Linux 6.14.11-2-pve #1 SMP', memory: { total: 34359738368, used: 17179869184, free: 17179869184 }, swap: { total: 0, used: 0, free: 0 }, rootfs: { total: 100, used: 40, avail: 60, free: 60 }, cpuinfo: { model: 'Fixture CPU', cores: 4, cpus: 8, sockets: 1 }, 'boot-info': { mode: 'efi', secureboot: 0 }, 'current-kernel': { release: '6.14.11-2-pve', sysname: 'Linux', machine: 'x86_64', version: '#1 SMP' } } });
  if (p === '/nodes/pve1/storage') return json(res, 200, { data: [{ storage: 'local', type: 'dir', content: 'iso,backup', active: 1, enabled: 1, shared: 0, total: 1000, used: 250, avail: 750 }, { storage: 'nfs-backup', type: 'nfs', content: 'backup', active: 0, enabled: 1, shared: 1 }] });
  if (p === '/nodes/pve1/disks/list') {
    if (req.headers.authorization?.includes('auditor-less')) return json(res, 403, { data: null, message: 'Permission check failed (/nodes/pve1, Sys.Audit)\n' });
    return json(res, 200, { data: [{ devpath: '/dev/sdb', model: 'ST4000VN006', serial: 'Z1', size: 4000787030016, health: 'FAILED', used: 'LVM', gpt: 1, mounted: 0, osdid: -1, wwn: 'x' }, { devpath: '/dev/nvme0n1', model: 'Samsung 990', serial: 'S1', size: 2000398934016, health: 'PASSED', used: 'ZFS', gpt: 1, mounted: 0, osdid: -1 }] });
  }
  if (p === '/nodes/pve1/disks/smart') {
    const disk = url.searchParams.get('disk');
    if (disk === '/dev/nvme0n1') return json(res, 200, { data: { health: 'PASSED', type: 'text', text: 'Percentage Used: 3%\nMedia and Data Integrity Errors: 0\n' } });
    if (disk === '/dev/sdb') return json(res, 200, { data: { health: 'FAILED', type: 'ata', attributes: [{ id: '  5', name: 'Reallocated_Sector_Ct', value: 5, worst: 5, threshold: 10, raw: '3912', fail: 'FAILING_NOW', flags: 'PO--CK', normalized: 5 }, { id: '194', name: 'Temperature_Celsius', value: 64, worst: 52, threshold: 0, raw: '36 (Min/Max 18/48)', fail: '-', flags: '-O---K' }] } });
    return json(res, 400, { data: null, errors: { disk: 'invalid' } });
  }
  if (p === '/nodes/pve1/tasks/UPID:pve1:9:failed/log') return json(res, 200, { data: [{ n: 2, t: 'TASK ERROR: job errors' }, { n: 1, t: "ERROR: storage 'nfs-backup' is not online" }], total: 2 });
  if (p === '/nodes/pve1/qemu/100/status/shutdown' && req.method === 'POST') { record('pve shutdown 100'); proxmoxPolls = 0; return json(res, 200, { data: 'UPID:pve1:0000ABCD:0001:66F1:qmshutdown:100:ci@pve!homelab:' }); }
  if (p === '/nodes/pve1/tasks/UPID:pve1:0000ABCD:0001:66F1:qmshutdown:100:ci@pve!homelab:/status') {
    proxmoxPolls += 1;
    return json(res, 200, { data: proxmoxPolls < 2 ? { status: 'running' } : { status: 'stopped', exitstatus: 'OK' } });
  }
  return json(res, 404, { data: null, errors: { path: 'not found' } });
}

async function portainer(req, res, url) {
  if (req.headers['x-api-key'] !== 'ptr_fixture') return json(res, 401, { message: 'Unauthorized', details: 'A valid authorisation token is missing' });
  const p = url.pathname.replace('/portainer/api', '');
  if (p === '/system/status') return json(res, 200, { Version: '2.33.1', instanceID: 'x' });
  if (p === '/endpoints') return json(res, 200, [{ Id: 1, Name: 'local', Type: 1, Status: 1, URL: 'unix:///var/run/docker.sock' }]);
  if (p === '/stacks') return json(res, 200, [{ Id: 3, Name: 'monitoring', Type: 2, EndpointId: 1, Status: 1 }]);
  if (p === '/endpoints/1/docker/containers/json' && url.searchParams.get('all') === '1') return json(res, 200, [{ Id: 'c1', Names: ['/grafana'], Image: 'grafana/grafana', State: 'running', Status: 'Up 1 hour', Created: 1, Labels: { 'com.docker.compose.project': 'monitoring' } }]);
  if (p === '/endpoints/1/docker/containers/c1/logs') {
    const frame = (stream, s) => { const b = Buffer.from(s); const h = Buffer.alloc(8); h[0] = stream; h.writeUInt32BE(b.length, 4); return Buffer.concat([h, b]); };
    res.writeHead(200, { 'Content-Type': 'application/vnd.docker.raw-stream' });
    return res.end(Buffer.concat([frame(1, 'started\n'), frame(2, 'warning: slow\n')]));
  }
  if (p === '/endpoints/1/docker/containers/c1/start' && req.method === 'POST') { record('portainer start c1'); res.writeHead(304); return res.end(); }
  if (p === '/endpoints/1/docker/containers/c1/json') return json(res, 200, { Id: 'c1', Name: '/grafana', RestartCount: 3, State: { Status: 'running', Running: true, Paused: false, Restarting: false, OOMKilled: true, Dead: false, Pid: 1, ExitCode: 137, Error: '', StartedAt: '2026-09-29T09:00:00.123456789Z', FinishedAt: '2026-09-29T08:59:58Z', Health: { Status: 'unhealthy', FailingStreak: 2, Log: [{ Start: '2026-09-29T09:59:30Z', End: '2026-09-29T09:59:31Z', ExitCode: 1, Output: 'connection refused\n' }] } }, HostConfig: { RestartPolicy: { Name: 'on-failure', MaximumRetryCount: 5 } }, Config: { Env: ['GF_SECURITY_ADMIN_PASSWORD=must-not-be-read'] } });
  if (p === '/stacks/3/stop' && req.method === 'POST') { record(`portainer stop stack 3 endpoint=${url.searchParams.get('endpointId')}`); return json(res, 200, { Id: 3, Status: 2 }); }
  return json(res, 404, { message: 'Not found' });
}


const piholeSessions = new Set();
async function pihole(req, res, url) {
  const p = url.pathname.replace('/pihole/api', '');
  if (p === '/auth' && req.method === 'POST') {
    const body = JSON.parse(await readBody(req));
    if (body.password !== 'app-password') return json(res, 401, { session: { valid: false, totp: false, sid: null, validity: -1, message: 'password incorrect' } });
    const sid = `sid-${piholeSessions.size + 1}`;
    piholeSessions.add(sid);
    return json(res, 200, { session: { valid: true, totp: false, sid, csrf: 'c', validity: 300, message: 'app-password correct' } });
  }
  const sid = req.headers['x-ftl-sid'];
  if (!piholeSessions.has(sid)) return json(res, 401, { error: { key: 'unauthorized', message: 'Unauthorized' } });
  if (p === '/auth' && req.method === 'DELETE') { piholeSessions.delete(sid); record(`pihole logout ${sid}`); res.writeHead(204); return res.end(); }
  if (p === '/stats/summary') return json(res, 200, { queries: { total: 1000, blocked: 250, percent_blocked: 25, cached: 400, forwarded: 350, unique_domains: 90 }, clients: { active: 12, total: 20 }, gravity: { domains_being_blocked: 123456, last_update: 1 }, took: 0.001 });
  if (p === '/dns/blocking' && req.method === 'GET') return json(res, 200, { blocking: 'enabled', timer: null, took: 0.001 });
  if (p === '/dns/blocking' && req.method === 'POST') { const b = JSON.parse(await readBody(req)); record(`pihole blocking ${b.blocking} timer=${b.timer}`); return json(res, 200, { blocking: b.blocking ? 'enabled' : 'disabled', timer: b.timer }); }
  if (p === '/info/version') return json(res, 200, { version: { core: { local: { version: 'v6.1.4' } } } });
  if (p === '/queries') {
    if (url.searchParams.get('length') !== '50') return json(res, 400, { error: { key: 'bad_request', message: 'length expected' } });
    return json(res, 200, { queries: [
      { id: 2, time: 1759140000.5, type: 'A', domain: 'ads.example.net', cname: null, status: 'GRAVITY', client: { ip: '192.168.1.40', name: 'tv.lan' }, dnssec: 'UNKNOWN', reply: { type: 'BLOB', time: 0.2 }, list_id: 3, upstream: null },
      { id: 1, time: 1759139990.1, type: 'AAAA', domain: 'example.org', cname: null, status: 'FORWARDED', client: { ip: '192.168.1.41', name: null }, dnssec: 'INSECURE', reply: { type: 'IP', time: 12 }, list_id: null, upstream: '1.1.1.1#53' },
      { id: 0, time: 1759139980.1, type: 'A', domain: 'cached.example', cname: null, status: 'CACHE', client: { ip: '192.168.1.41', name: '' }, reply: { type: 'IP', time: 0.1 } }], cursor: 2, recordsTotal: 3, recordsFiltered: 3, draw: 0, took: 0.003 });
  }
  if (p.startsWith('/search/')) {
    const domain = decodeURIComponent(p.slice('/search/'.length));
    if (url.searchParams.get('partial') !== 'false') return json(res, 400, { error: { key: 'bad_request', message: 'partial expected' } });
    const allowed = piholeAllowed.has(domain);
    return json(res, 200, { search: {
      domains: allowed ? [{ domain, type: 'allow', kind: 'exact', enabled: true, id: 9, groups: [0] }] : [],
      gravity: domain === 'ads.example.net' ? [{ domain, address: 'https://lists.example.org/hosts', type: 'block', enabled: true, id: 3 }] : [],
      parameters: { partial: false, N: 20, domain }, results: { total: 1 } }, took: 0.002 });
  }
  if (p === '/info/messages') return json(res, 200, { messages: [{ id: 5, timestamp: 1759130000.1, type: 'RATE_LIMIT', plain: 'Rate-limiting 192.168.1.42 for at least 5 seconds', html: '' }], took: 0.001 });
  if (p === '/action/gravity' && req.method === 'POST') { record('pihole gravity'); res.writeHead(200, { 'Content-Type': 'text/plain' }); res.write('  [i] Neutrino emissions detected...\n'); return res.end('  [✓] Done.\n'); }
  if (p === '/action/restartdns' && req.method === 'POST') { record('pihole restartdns'); return json(res, 200, { status: 'restarting', took: 0.001 }); }
  if (p === '/domains/allow/exact' && req.method === 'POST') {
    const b = JSON.parse(await readBody(req));
    if (typeof b.domain !== 'string' || b.enabled !== true) return json(res, 400, { error: { key: 'bad_request', message: 'domain expected' } });
    piholeAllowed.add(b.domain);
    record(`pihole allow ${b.domain}`);
    return json(res, 201, { domains: [{ domain: b.domain, type: 'allow', kind: 'exact', enabled: true, id: 9 }], processed: { success: [{ item: b.domain }], errors: [] }, took: 0.002 });
  }
  return json(res, 404, { error: { key: 'not_found', message: 'Not found' } });
}

async function adguard(req, res, url) {
  if (req.headers.authorization !== `Basic ${Buffer.from('admin:guard').toString('base64')}`) return text(res, 401, 'Unauthorized');
  const p = url.pathname.replace('/adguard/control', '');
  if (p === '/status') return json(res, 200, { version: 'v0.107.66', protection_enabled: true, protection_disabled_duration: 0, running: true, dns_addresses: [], dns_port: 53, http_port: 80 });
  if (p === '/stats') return json(res, 200, { num_dns_queries: 2000, num_blocked_filtering: 300, num_replaced_safebrowsing: 10, num_replaced_parental: 0, avg_processing_time: 0.012 });
  if (p === '/protection' && req.method === 'POST') { const b = JSON.parse(await readBody(req)); record(`adguard protection ${b.enabled} duration=${b.duration}`); return text(res, 200, 'OK'); }
  if (p === '/querylog') {
    if (url.searchParams.get('limit') !== '50') return json(res, 400, { message: 'limit expected' });
    return json(res, 200, { oldest: '2026-09-29T09:00:00+00:00', data: [
      { time: '2026-09-29T10:00:00.5+00:00', client: '192.168.1.40', client_info: { name: 'tv', disallowed: false, disallowed_rule: '', whois: {} }, question: { class: 'IN', name: 'ads.example.net', type: 'A' }, reason: 'FilteredBlackList', rules: [{ filter_list_id: 1, text: '||ads.example.net^' }], status: 'NOERROR', elapsedMs: '0.2', cached: false },
      { time: '2026-09-29T09:59:00+00:00', client: '192.168.1.41', client_info: { name: '', disallowed: false, disallowed_rule: '', whois: {} }, question: { class: 'IN', name: 'xn--80ak6aa92e.com', unicode_name: 'аррӏе.com', type: 'A' }, reason: 'NotFilteredNotFound', status: 'NOERROR', elapsedMs: '9', cached: true }] });
  }
  if (p === '/filtering/check_host') {
    const name = url.searchParams.get('name');
    if (name === 'ads.example.net') return json(res, 200, { reason: 'FilteredBlackList', rules: [{ filter_list_id: 1, text: '||ads.example.net^' }] });
    if (name === 'nas.home.arpa') return json(res, 200, { reason: 'Rewrite', rules: [], cname: '', ip_addrs: ['192.168.1.10'] });
    return json(res, 200, { reason: 'NotFilteredNotFound', rules: [] });
  }
  if (p === '/filtering/refresh' && req.method === 'POST') { const b = JSON.parse(await readBody(req)); record(`adguard refresh whitelist=${b.whitelist}`); return json(res, 200, { updated: 2 }); }
  return text(res, 404, '');
}

async function unifi(req, res, url) {
  if (req.headers['x-api-key'] !== 'unifi-key') return json(res, 401, { statusCode: 401, statusName: 'UNAUTHORIZED', message: 'Missing credentials' });
  const p = url.pathname.replace('/unifi/proxy/network/integration/v1', '');
  const page = (all) => { const offset = Number(url.searchParams.get('offset') ?? 0); const limit = Math.min(Number(url.searchParams.get('limit') ?? 25), 1); const data = all.slice(offset, offset + limit); return { offset, limit, count: data.length, totalCount: all.length, data }; };
  if (p === '/info') return json(res, 200, { applicationVersion: '10.6.106' });
  if (p === '/sites') return json(res, 200, page([{ id: 'site-1', internalReference: 'default', name: 'Default' }]));
  if (p === '/sites/site-1/devices') return json(res, 200, page([{ id: 'dev-1', name: 'Gateway', model: 'UCG-Ultra', macAddress: 'aa', ipAddress: '10.0.0.1', state: 'ONLINE', supported: true, firmwareVersion: '4.3.9', firmwareUpdatable: false, features: ['gateway'], interfaces: [] }, { id: 'dev-2', name: 'AP', model: 'U7-Pro', state: 'OFFLINE', features: ['accessPoint'], interfaces: [] }]));
  if (p === '/sites/site-1/clients') return json(res, 200, page([{ type: 'WIRELESS', id: 'cl-1', name: 'Phone', connectedAt: '2026-09-01T00:00:00Z', ipAddress: '10.0.0.50', access: { type: 'DEFAULT' }, macAddress: 'bb', uplinkDeviceId: 'dev-2' }]));
  if (p === '/sites/site-1/devices/dev-1/actions' && req.method === 'POST') { const b = JSON.parse(await readBody(req)); record(`unifi ${b.action} dev-1`); return json(res, 200, {}); }
  if (p === '/sites/site-1/devices/dev-1') return json(res, 200, { id: 'dev-1', name: 'Gateway', model: 'UCG-Ultra', supported: true, macAddress: 'aa', ipAddress: '10.0.0.1', state: 'ONLINE', firmwareVersion: '4.3.9', firmwareUpdatable: false, configurationId: 'c', features: { switching: {} },
    interfaces: { ports: [{ idx: 1, state: 'UP', connector: 'RJ45', maxSpeedMbps: 2500, speedMbps: 1000 }, { idx: 2, state: 'UP', connector: 'RJ45', maxSpeedMbps: 1000, speedMbps: 1000, poe: { standard: '802.3at', type: 2, enabled: true, state: 'UP' } }, { idx: 3, state: 'DOWN', connector: 'SFPPLUS', maxSpeedMbps: 10000 }] }, uplink: { deviceId: 'isp' } });
  if (p === '/sites/site-1/devices/dev-1/statistics/latest') return json(res, 200, { uptimeSec: 86400, lastHeartbeatAt: '2026-09-29T10:00:00Z', nextHeartbeatAt: '2026-09-29T10:00:30Z', loadAverage1Min: 0.5, loadAverage5Min: 0.4, loadAverage15Min: 0.3, cpuUtilizationPct: 7.5, memoryUtilizationPct: 52, uplink: { txRateBps: 2000000, rxRateBps: 25000000 }, interfaces: { radios: [] } });
  const portAction = p.match(/^\/sites\/site-1\/devices\/dev-1\/interfaces\/ports\/(\d+)\/actions$/);
  if (portAction && req.method === 'POST') {
    const b = JSON.parse(await readBody(req));
    if (b.action !== 'POWER_CYCLE') return json(res, 400, { statusCode: 400, statusName: 'BAD_REQUEST', message: 'Unknown action' });
    if (portAction[1] !== '2') return json(res, 400, { statusCode: 400, statusName: 'BAD_REQUEST', message: 'Port does not support PoE' });
    record(`unifi POWER_CYCLE port ${portAction[1]}`);
    return json(res, 200, {});
  }
  return json(res, 404, { statusCode: 404, statusName: 'NOT_FOUND', message: 'Not found' });
}

async function homeAssistant(req, res, url) {
  const nonAdmin = req.headers.authorization === 'Bearer ha-user-token';
  if (req.headers.authorization !== 'Bearer ha-token' && !nonAdmin) return text(res, 401, '401: Unauthorized');
  const p = url.pathname.replace('/ha/api', '');
  // Home Assistant restricts the error log to administrators.
  if (nonAdmin && p === '/error_log') return text(res, 401, '401: Unauthorized');
  if (p === '/config') return json(res, 200, { version: '2026.9.2', location_name: 'Fixture Home', unit_system: {} });
  if (p === '/states') return json(res, 200, [{ entity_id: 'light.kitchen', state: 'off', attributes: { friendly_name: 'Kitchen' }, last_changed: '2026-09-01T00:00:00+00:00' }, { entity_id: 'lock.front', state: 'locked', attributes: { friendly_name: 'Front door' } }]);
  if (p === '/template' && req.method === 'POST') {
    const b = JSON.parse(await readBody(req));
    if (!b.template.includes('areas()') || !b.template.includes('area_entities')) return text(res, 400, 'bad template');
    return text(res, 200, JSON.stringify([{ id: 'kitchen', name: 'Kitchen', entities: ['light.kitchen'] }]));
  }
  const service = p.match(/^\/services\/(\w+)\/(\w+)$/);
  if (service && req.method === 'POST') { const b = JSON.parse(await readBody(req)); record(`ha ${service[1]}.${service[2]} ${b.entity_id}`); return json(res, 200, []); }
  if (p === '/config/core/check_config' && req.method === 'POST') return json(res, 200, { result: 'invalid', errors: 'Integration error: frontend - Integration not found.' });
  if (p === '/error_log') return text(res, 200, '2026-09-29 09:15:40.022 ERROR (MainThread) [homeassistant.components.mqtt] Error connecting to MQTT broker\n2026-09-29 09:16:02.871 INFO (MainThread) [homeassistant.components.mqtt] Reconnected\n');
  return text(res, 404, '404: Not Found');
}

function tailscale(req, res, url) {
  if (req.headers.authorization !== 'Bearer tskey-api-fixture') return json(res, 401, { message: 'API token invalid' });
  if (url.pathname === '/tailscale/api/v2/tailnet/-/devices') return json(res, 200, { devices: [{ id: '1', name: 'atlas.tail.ts.net', hostname: 'atlas', os: 'linux', addresses: ['100.64.0.1'], connectedToControl: true, expires: '2020-01-01T00:00:00Z', keyExpiryDisabled: false, authorized: true, updateAvailable: false }] });
  return json(res, 404, { message: 'not found' });
}

function cloudflare(req, res, url) {
  const ok = (result) => json(res, 200, { success: true, errors: [], messages: [], result });
  if (req.headers.authorization !== 'Bearer cf-token') return json(res, 401, { success: false, errors: [{ code: 1000, message: 'Invalid API Token' }], messages: [], result: null });
  const p = url.pathname.replace('/cloudflare/client/v4', '');
  if (p === '/user/tokens/verify') return ok({ id: 'tok', status: 'active' });
  if (p === '/accounts/acct-1/cfd_tunnel') return ok([{ id: 'tun-1', name: 'home', status: 'degraded', connections: [{ colo_name: 'sea01', is_pending_reconnect: false }], created_at: '2026-01-01T00:00:00Z' }]);
  if (p === '/zones') return json(res, 403, { success: false, errors: [{ code: 9109, message: 'Unauthorized to access requested resource' }], messages: [], result: null });
  return json(res, 404, { success: false, errors: [{ code: 7003, message: 'No route' }], result: null });
}


async function ntfy(req, res, url) {
  if (req.headers.authorization !== 'Bearer tk_fixture') return json(res, 403, { code: 40301, http: 403, error: 'forbidden' });
  const topic = url.pathname.split('/')[2];
  if (req.method === 'POST') { record(`ntfy publish ${topic} title=${req.headers.title} priority=${req.headers.priority} body=${await readBody(req)}`); return json(res, 200, { id: 'pub1', time: 1, event: 'message', topic }); }
  if (url.pathname.endsWith('/json') && url.searchParams.get('poll') === '1') {
    record(`ntfy poll since=${url.searchParams.get('since')}`);
    res.writeHead(200, { 'Content-Type': 'application/x-ndjson' });
    return res.end([
      { id: 'o1', time: 1700000000, event: 'open', topic },
      { id: 'm1', time: 1700000001, event: 'message', topic, title: 'Disk alert', message: 'Disk full', priority: 5, tags: ['warning'] },
      { id: 'k1', time: 1700000002, event: 'keepalive', topic },
      { id: 'm2', time: 1700000003, event: 'message', topic, message: 'Backup done' },
    ].map((m) => JSON.stringify(m)).join('\n') + '\n');
  }
  return json(res, 404, { error: 'not found' });
}


const basic = (user, pass) => `Basic ${Buffer.from(`${user}:${pass}`).toString('base64')}`;
const lo = (n) => n % 2 ** 32;
const hi = (n) => Math.floor(n / 2 ** 32);

async function nzbget(req, res) {
  if (req.headers.authorization !== basic('nzb', 'get')) { res.writeHead(401, { 'WWW-Authenticate': 'Basic realm="NZBGet"' }); return res.end(); }
  const body = JSON.parse(await readBody(req));
  const reply = (result) => json(res, 200, { version: '1.1', id: body.id, result });
  switch (body.method) {
    case 'version': return reply('25.3');
    case 'status': return reply({ DownloadRateLo: 3 * 1024 * 1024, DownloadRateHi: 0, DownloadRate: 0, DownloadPaused: false, FreeDiskSpaceLo: 0, FreeDiskSpaceHi: 1 });
    case 'listgroups': {
      const size = 6 * 2 ** 32; const remaining = 3 * 2 ** 32;
      return reply([
        { NZBID: 5, NZBName: 'Linux.ISO.Collection', Status: 'DOWNLOADING', Category: 'software', FileSizeLo: lo(size), FileSizeHi: hi(size), RemainingSizeLo: lo(remaining), RemainingSizeHi: hi(remaining), PausedSizeLo: 0, PausedSizeHi: 0, Health: 1000, CriticalHealth: 898, PostInfoText: '', PostStageProgress: 0, PostStageTimeSec: 0 },
        { NZBID: 6, NZBName: 'Conference.Talks', Status: 'UNPACKING', Category: '', FileSizeLo: 1000, FileSizeHi: 0, RemainingSizeLo: 0, RemainingSizeHi: 0, PausedSizeLo: 0, PausedSizeHi: 0, Health: 1000, CriticalHealth: 898, PostInfoText: 'Unpacking Conference.Talks', PostStageProgress: 250, PostStageTimeSec: 30 },
      ]);
    }
    case 'editqueue': record(`nzbget ${body.params[0]} ${body.params[2].join(',')}`); return reply(body.params[2].includes(5));
    case 'pausedownload': case 'resumedownload': record(`nzbget ${body.method}`); return reply(true);
    default: return json(res, 200, { version: '1.1', id: body.id, error: { name: 'JSONRPCError', code: 1, message: 'Invalid procedure' } });
  }
}

let delugeConnected = false;
async function deluge(req, res) {
  const body = JSON.parse(await readBody(req));
  const reply = (result, headers = {}) => json(res, 200, { result, error: null, id: body.id }, headers);
  const fail = (code, message) => json(res, 200, { result: null, error: { message, code }, id: body.id });
  if (body.method === 'auth.login') {
    if (body.params[0] !== 'deluge-pw') return reply(false);
    return reply(true, { 'Set-Cookie': '_session_id=fixture123; Path=/' });
  }
  if (body.method.startsWith('core.') || body.method.startsWith('daemon.')) {
    if (!delugeConnected) return fail(2, 'Unknown method');
  }
  if (!(req.headers.cookie ?? '').includes('_session_id=fixture123')) return fail(1, 'Not authenticated');
  switch (body.method) {
    case 'web.connected': return reply(delugeConnected);
    case 'web.get_hosts': return reply([['host-a', '127.0.0.1', 58846, 'localclient']]);
    case 'web.get_host_status': return reply([body.params[0], 'Online', '2.2.0']);
    case 'web.connect': delugeConnected = true; record('deluge connect host-a'); return reply(['core.get_torrents_status']);
    case 'daemon.get_version': return reply('2.2.0');
    case 'core.is_session_paused': return reply(false);
    case 'web.update_ui': return reply({ connected: true, torrents: { abc: { name: 'ubuntu.iso', state: 'Downloading', progress: 42.5, total_wanted: 1000, total_remaining: 575, download_payload_rate: 2048, upload_payload_rate: 10, eta: 60, label: 'linux', message: 'OK' }, def: { name: 'broken.iso', state: 'Error', progress: 100, total_wanted: 5, total_remaining: 0, download_payload_rate: 0, upload_payload_rate: 0, eta: 0, message: 'Tracker unreachable' } }, stats: { download_rate: 2048.0, upload_rate: 10.0 } });
    case 'core.pause_torrent': record(`deluge pause ${body.params[0].join(',')}`); return reply(null);
    case 'core.pause_session': record('deluge pause_session'); return reply(null);
    case 'core.remove_torrents': record(`deluge remove ${body.params[0].join(',')} data=${body.params[1]}`); return reply([]);
    default: return fail(2, 'Unknown method');
  }
}

async function bazarr(req, res, url) {
  if (req.headers['x-api-key'] !== 'bazarr-key') return text(res, 401, 'Unauthorized');
  const p = url.pathname.replace('/bazarr/api', '');
  const lang = { name: 'English', code2: 'en', code3: 'eng', forced: false, hi: false };
  if (p === '/system/status') return json(res, 200, { data: { bazarr_version: '1.6.2', sonarr_version: '4.0.15', radarr_version: '', start_time: 1759100000.1 } });
  if (p === '/badges') return json(res, 200, { episodes: 2, movies: 1, providers: 1, status: 1, sonarr_signalr: 'LIVE', radarr_signalr: 'DOWN', announcements: 0 });
  if (p === '/system/health') return json(res, 200, { data: [{ object: '/tv', issue: 'Path does not exist' }] });
  if (p === '/providers' && req.method === 'GET') return json(res, 200, { data: [{ name: 'opensubtitlescom', status: 'Good', retry: '-' }, { name: 'podnapisi', status: 'TooManyRequests', retry: 'in 2 hours' }] });
  if (p === '/providers' && req.method === 'POST') { record(`bazarr providers ${new URLSearchParams(await readBody(req)).get('action')}`); res.writeHead(204); return res.end(); }
  if (p === '/system/tasks' && req.method === 'GET') return json(res, 200, { data: [{ interval: 'every 6 hours', job_id: 'wanted_search_missing_subtitles_series', job_running: false, name: 'Search for Missing Series Subtitles', next_run_in: 'in 3 hours', next_run_time: 'in 3 hours' }] });
  if (p === '/system/tasks' && req.method === 'POST') { record(`bazarr task ${new URLSearchParams(await readBody(req)).get('taskid')}`); res.writeHead(204); return res.end(); }
  if (p === '/episodes/wanted') {
    if (url.searchParams.get('length') !== '25') return json(res, 400, { message: 'length expected' });
    return json(res, 200, { data: [{ seriesTitle: 'Pioneer One', episode_number: '1x4', episodeTitle: 'Sermon', missing_subtitles: [lang, { ...lang, name: 'Spanish', code2: 'es', hi: true }], sonarrSeriesId: 12, sonarrEpisodeId: 3456, sceneName: null, tags: [], seriesType: 'standard' }], total: 40 });
  }
  if (p === '/movies/wanted') return json(res, 200, { data: [{ title: 'Sintel', missing_subtitles: [lang], radarrId: 77, sceneName: null, tags: [] }], total: 1 });
  if (p === '/episodes/subtitles' && req.method === 'PATCH') { const f = new URLSearchParams(await readBody(req)); record(`bazarr episode ${f.get('seriesid')}/${f.get('episodeid')} ${f.get('language')} forced=${f.get('forced')} hi=${f.get('hi')}`); res.writeHead(204); return res.end(); }
  return json(res, 404, { message: 'not found' });
}

async function hydra(req, res, url) {
  const p = url.pathname.replace('/hydra', '');
  if (p.startsWith('/externalapi/')) { res.writeHead(404); return res.end(); }
  if (p === '/api' && url.searchParams.get('t') === 'caps') {
    if (url.searchParams.get('apikey') !== 'hydra-key') return text(res, 200, '<error code="100" description="Wrong api key"/>');
    return json(res, 200, { server: { '@attributes': { version: '8.5.0', title: 'NZBHydra 2' } } });
  }
  if (p === '/api/stats/indexers' && req.method === 'POST') {
    const body = JSON.parse(await readBody(req));
    if (body.apikey !== 'hydra-key') return json(res, 403, { message: 'Stats access forbidden' });
    return json(res, 200, [
      { indexer: 'Usenet Index', state: 'ENABLED', level: 0, disabledUntil: null, lastError: null, apiHits: 42, apiHitLimit: 100, downloadHits: 3, downloadHitLimit: null },
      { indexer: 'Archive', state: 'DISABLED_SYSTEM_TEMPORARY', level: 2, disabledUntil: 1790000000.5, lastError: 'Connection refused' },
    ]);
  }
  return json(res, 404, {});
}

function jackett(req, res, url) {
  const xml = (body) => { res.writeHead(200, { 'Content-Type': 'application/xml' }); res.end(`<?xml version="1.0" encoding="UTF-8"?>${body}`); };
  if (url.searchParams.get('apikey') !== 'jackett-key') return xml('<error code="100" description="Invalid API Key" />');
  const match = url.pathname.match(/^\/jackett\/api\/v2\.0\/indexers\/([^/]+)\/results\/torznab\/api$/);
  if (!match) return text(res, 404, '');
  if (match[1] === 'all' && url.searchParams.get('t') === 'indexers' && url.searchParams.get('configured') === 'true') {
    return xml('<indexers><indexer id="linuxtracker" configured="true"><title>Linux Tracker</title><description>d</description><link>https://linuxtracker.example/</link><language>en-US</language><type>public</type><caps><server title="Jackett" /></caps></indexer><indexer id="club" configured="true"><title>Private &amp; Club</title><link>https://club.example/</link><language>en-GB</language><type>private</type><caps /></indexer></indexers>');
  }
  if (url.searchParams.get('t') === 'search') {
    record(`jackett test ${match[1]}`);
    if (match[1] === 'club') return xml('<error code="900" description="Login failed" />');
    return xml('<rss version="2.0"><channel><item><title>a</title></item><item><title>b</title></item></channel></rss>');
  }
  return xml('<error code="203" description="Function Not Available" />');
}

async function tdarr(req, res, url) {
  if (req.headers['x-api-key'] !== 'tapi_fixture') return json(res, 401, { message: 'Unauthorized' });
  const p = url.pathname.replace('/tdarr/api/v2', '');
  if (p === '/status') return json(res, 200, { status: 'good', version: '2.92.01', uptime: 100 });
  if (p === '/get-nodes') return json(res, 200, { nodeA: { _id: 'nodeA', nodeName: 'Tower', nodePaused: false, workers: { w1: { idle: false, file: '/media/a.mkv', job: { jobId: 'j1', footprintId: 'f' } }, w2: { idle: true } } } });
  if (p === '/poll-worker-limits' && req.method === 'POST') { const b = JSON.parse(await readBody(req)); return json(res, 200, { workerLimits: { transcodecpu: 2 }, queueLengths: { transcodecpu: 7, healthcheckcpu: '2' }, lowCPUPriority: false, echo: b.data.nodeID }); }
  if (p === '/update-node' && req.method === 'POST') { const b = JSON.parse(await readBody(req)); record(`tdarr node ${b.data.nodeID} paused=${b.data.nodeUpdates.nodePaused}`); return json(res, 200, 'OK'); }
  return json(res, 404, {});
}

async function maintainerr(req, res, url) {
  const p = decodeURIComponent(url.pathname.replace('/maintainerr/api', ''));
  if (p === '/app/status') { res.writeHead(200, { 'Content-Type': 'text/html' }); return res.end(JSON.stringify({ status: 1, version: '3.29.0', commitTag: 'latest', updateAvailable: true })); }
  if (p === '/health') return json(res, 200, { status: 'ok', uptimeSeconds: 10, database: 'ok', timestamp: '2026-09-29T00:00:00.000Z' });
  if (p === '/rules/execute/status') return json(res, 200, { processingQueue: false, executingRuleGroupId: null, pendingRuleGroupIds: [], queue: [] });
  if (p === '/tasks/Collection Handler/status') return json(res, 200, { time: '2026-09-29T00:00:00.000Z', running: false, runningSince: null });
  if (p === '/collections') return json(res, 200, [
    { id: 1, title: 'Leaving Soon', isActive: true, arrAction: 0, deleteAfterDays: 30, type: 'movie', mediaServerType: 'plex', mediaCount: 3, totalSizeBytes: '53687091200', media: [] },
    { id: 2, title: 'Paused', isActive: false, arrAction: 4, deleteAfterDays: null, type: 'show', mediaServerType: 'plex', mediaCount: 0, totalSizeBytes: null, media: [] },
  ]);
  if (p === '/collections/media' && url.searchParams.get('collectionId') === '1') return json(res, 200, [
    { id: 1, collectionId: 1, addDate: '2020-01-01T00:00:00.000Z' }, { id: 2, collectionId: 1, addDate: new Date().toISOString() }, { id: 3, collectionId: 1, addDate: null },
  ]);
  if (p === '/rules/execute' && req.method === 'POST') { record('maintainerr execute rules'); res.writeHead(201); return res.end(); }
  if (p === '/collections/handle' && req.method === 'POST') { record('maintainerr handle collections'); res.writeHead(201); return res.end(); }
  return json(res, 404, { statusCode: 404, message: 'Not Found' });
}

function tautulli(req, res, url) {
  const envelope = (status, result, message, data) => json(res, status, { response: { result, message, data } });
  const key = url.searchParams.get('apikey');
  if (!key) return envelope(401, 'error', 'Parameter apikey is required or X-Api-Key header is required', {});
  if (key !== 'tautulli-key-0000000000000000000') return envelope(401, 'error', 'Invalid apikey', {});
  switch (url.searchParams.get('cmd')) {
    case 'get_tautulli_info': return envelope(200, 'success', null, { tautulli_version: 'v2.18.2', tautulli_branch: 'master' });
    case 'get_logs':
      if (url.searchParams.get('order') !== 'desc' || url.searchParams.get('end') !== '200') return envelope(400, 'error', 'order and end expected', null);
      return envelope(200, 'success', null, [
        { loglevel: 'ERROR', msg: 'Tautulli Webhook :: Request failed: https://hooks.example.com/x?token=abc123secret', thread: 'Thread-1', time: '2026-09-29 09:41:02 ' },
        { loglevel: 'INFO', msg: 'Tautulli Monitor :: Session started', thread: 'Thread-2', time: '2026-09-29 09:40:00 ' },
        { loglevel: 'WARNING', msg: 'Tautulli Notifiers :: Discord rate limited', thread: 'Thread-3', time: '2026-09-29 09:30:00 ' }]);
    case 'get_notification_log':
      return envelope(200, 'success', null, { draw: 1, recordsTotal: 4, recordsFiltered: 4, data: [
        { id: 4, agent_name: 'discord', notify_action: 'on_play', success: 0, timestamp: 1759140000, body_text: 'secret body', user: 'someone' },
        { id: 3, agent_name: 'discord', notify_action: 'on_stop', success: 1, timestamp: 1759139000 },
        { id: 2, agent_name: 'email', notify_action: 'on_created', success: 1, timestamp: 1759138000 },
        { id: 1, agent_name: 'discord', notify_action: 'on_play', success: 0, timestamp: 1759130000 }] });
    case 'get_server_info': return envelope(200, 'success', null, { pms_name: 'Tower', pms_version: '1.42.1.10060', pms_plexpass: 1 });
    case 'server_status': return envelope(200, 'success', null, { connected: true });
    case 'get_activity': return envelope(200, 'success', null, { stream_count: '1', stream_count_direct_play: 0, stream_count_direct_stream: 0, stream_count_transcode: 1, total_bandwidth: 4200, lan_bandwidth: 0, wan_bandwidth: 4200, sessions: [{ session_key: '27', session_id: 'sess-1', friendly_name: 'Sam', full_title: 'Sintel', media_type: 'movie', state: 'playing', progress_percent: '76', player: 'iPhone', product: 'Plex for iOS', transcode_decision: 'transcode', stream_video_full_resolution: '720p', quality_profile: '4 Mbps 720p', location: 'wan', bandwidth: '4200', transcode_hw_encoding: 1,
      audio_decision: 'transcode', subtitle_decision: 'burn', stream_audio_codec: 'aac', audio_language: 'English', stream_audio_channel_layout: 'stereo', subtitle_language: 'English', subtitle_codec: 'pgs', stream_subtitle_codec: '' }] });
    case 'get_libraries': return envelope(200, 'success', null, [{ section_id: '2', section_name: 'TV Shows', section_type: 'show', count: '62', parent_count: '240', child_count: '3745', is_active: 1 }]);
    case 'get_history': return envelope(200, 'success', null, { draw: 1, recordsTotal: 1, data: [{ row_id: 1124, full_title: 'Pioneer One - Sermon', friendly_name: 'Alex', player: 'TV', started: 1462688107, percent_complete: 84 }] });
    case 'get_home_stats': return envelope(200, 'success', null, [{ stat_id: 'top_movies', stat_type: 'total_plays', rows: [{ title: 'Sintel', year: 2010, total_plays: 9, total_duration: 7200 }] }, { stat_id: 'top_tv', stat_type: 'total_plays', rows: [{ title: 'Pioneer One', total_plays: '14', total_duration: 30000 }] }, { stat_id: 'top_users', stat_type: 'total_plays', rows: [{ friendly_name: 'Alex', total_plays: 42, total_duration: 151200 }] }, { stat_id: 'top_platforms', rows: [{ platform: 'tvOS', total_plays: '38' }] }]);
    case 'get_users': return envelope(200, 'success', null, [{ user_id: '133788', username: 'Jon Snow', email: 'jon@example.com', is_active: 1 }, { user_id: 0, username: 'Local', is_active: 1 }, { user_id: '42', username: 'Former', is_active: 0 }]);
    case 'get_user_watch_time_stats':
      if (url.searchParams.get('user_id') !== '133788' || url.searchParams.get('query_days') !== '1,7,30,0') return envelope(400, 'error', 'user_id and query_days expected', null);
      return envelope(200, 'success', null, [{ query_days: 1, total_plays: 0, total_time: 0 }, { query_days: 7, total_plays: 3, total_time: 15694 }, { query_days: 30, total_plays: 35, total_time: 63054 }, { query_days: 0, total_plays: 508, total_time: 1183080 }]);
    case 'get_user_player_stats':
      if (url.searchParams.get('user_id') !== '133788') return envelope(400, 'error', 'user_id expected', null);
      return envelope(200, 'success', null, [{ platform: 'Chrome', player_name: 'Plex Web (Chrome)', result_id: 1, total_plays: 170, total_time: 349618 }]);
    case 'get_plays_by_date':
      if (!url.searchParams.get('time_range') || url.searchParams.get('y_axis') !== 'plays') return envelope(400, 'error', 'time_range and y_axis expected', null);
      if (url.searchParams.get('user_id') === '133788') return envelope(200, 'success', null, { categories: ['2026-09-28', '2026-09-29'], series: [{ name: 'TV', data: [2, 1] }] });
      return envelope(200, 'success', null, { categories: ['2026-09-27', '2026-09-28', '2026-09-29'], series: [{ name: 'Movies', data: [1, 0, 2] }, { name: 'TV', data: [3, 4, 0] }, { name: 'Music', data: [0, 0, 0] }, { name: 'Live TV', data: [0, 1, 0] }] });
    case 'refresh_libraries_list': case 'refresh_users_list': case 'backup_db': record(`tautulli ${url.searchParams.get('cmd')}`); return envelope(200, 'success', null, {});
    case 'terminate_session': record(`tautulli terminate ${url.searchParams.get('session_id')} message=${url.searchParams.get('message')}`); return envelope(400, 'error', 'Failed to terminate session: No Plex Pass subscription.', {});
    default: return envelope(400, 'error', 'Unknown command', {});
  }
}

async function komga(req, res, url) {
  if (req.headers['x-api-key'] !== 'komga-key') return json(res, 401, { error: 'Unauthorized' });
  if (req.headers.cookie) return json(res, 400, { error: 'session cookie sent with API key' });
  const p = url.pathname.replace('/komga', '');
  const page = (content, total) => json(res, 200, { content, totalElements: total, totalPages: 1, number: 0, size: content.length });
  const book = (id, status, comment) => ({ id, name: `Book ${id}`, seriesTitle: 'Pepper & Carrot', libraryId: 'l1', created: '2026-09-28T10:00:00Z', sizeBytes: 1000, media: { status, comment, mediaType: 'application/zip', pagesCount: 10 } });
  if (p === '/api/v2/users/me') return json(res, 200, { id: 'u', email: 'admin@example.com', roles: ['ADMIN', 'USER'] });
  if (p === '/actuator/info') return json(res, 200, { build: { version: '1.28.0' } });
  if (p === '/api/v1/libraries') return json(res, 200, [{ id: 'l1', name: 'Comics', root: '/comics', unavailable: false }]);
  if (p === '/api/v1/series/list' && req.method === 'POST') return page([{ id: 's1' }], 214);
  if (p === '/api/v1/books/list' && req.method === 'POST') {
    const body = JSON.parse(await readBody(req));
    if (body.condition) {
      const statuses = body.condition.anyOf.map((c) => c.mediaStatus.value);
      if (statuses.join() !== 'ERROR,UNSUPPORTED') return json(res, 400, { violations: [] });
      return page([book('b9', 'ERROR', 'ERR_1008')], 1);
    }
    if (url.searchParams.get('sort') === 'createdDate,desc') return page([book('b1', 'READY', '')], 3812);
    return page([book('b1', 'READY', '')], 3812);
  }
  const scan = p.match(/^\/api\/v1\/libraries\/(\w+)\/scan$/);
  if (scan && req.method === 'POST') { record(`komga scan ${scan[1]} deep=${url.searchParams.get('deep')}`); res.writeHead(202); return res.end(); }
  if (p === '/api/v1/tasks' && req.method === 'DELETE') { record('komga cancel tasks'); return json(res, 200, 4); }
  if (p === '/api/v1/releases') return json(res, 200, [{ version: '1.29.0', releaseDate: '2026-09-20T00:00:00Z', url: 'https://github.com/gotson/komga/releases/tag/1.29.0', latest: true, preRelease: false, description: '' }, { version: '1.28.0', releaseDate: '2026-08-01T00:00:00Z', url: '', latest: false, preRelease: false, description: '' }]);
  return json(res, 404, {});
}

let kavitaLogins = 0;
async function kavita(req, res, url) {
  const p = url.pathname.replace('/kavita', '');
  if (p === '/api/Plugin/authenticate' && req.method === 'POST') {
    if (url.searchParams.get('apiKey') !== 'kavita-key' || !url.searchParams.get('pluginName')) return json(res, 401, { message: 'Invalid API Key' });
    kavitaLogins += 1;
    return json(res, 200, { username: 'reader', token: `jwt-${kavitaLogins}`, refreshToken: 'r', apiKey: 'kavita-key', kavitaVersion: '0.9.1.4' });
  }
  // The first token is treated as expired to exercise re-authentication.
  const auth = req.headers.authorization ?? '';
  if (auth === 'Bearer jwt-1' || auth !== `Bearer jwt-${kavitaLogins}`) return text(res, 401, '');
  if (p === '/api/Library/libraries') return json(res, 200, [{ id: 1, name: 'Manga', type: 0, lastScanned: '2026-09-28T03:00:00.1234567' }]);
  if (p === '/api/Series/recently-added-v2' && req.method === 'POST') {
    const body = JSON.parse(await readBody(req));
    if (!Array.isArray(body.statements)) return json(res, 400, {});
    res.writeHead(200, { 'Content-Type': 'application/json', Pagination: JSON.stringify({ currentPage: 1, itemsPerPage: 10, totalItems: 188, totalPages: 19 }) });
    return res.end(JSON.stringify([{ id: 40, name: 'Creative Commons Stories', libraryName: 'Manga', created: '2026-09-27T10:00:00' }]));
  }
  if (p.startsWith('/api/Stats/') || p.startsWith('/api/Server/') || p.startsWith('/api/Activity/')) return text(res, 403, 'Forbidden');
  return text(res, 404, '');
}

async function audiobookshelf(req, res, url) {
  const p = url.pathname.replace('/abs', '');
  if (p === '/status') return json(res, 200, { app: 'audiobookshelf', serverVersion: '2.36.0', isInit: true });
  if (req.headers.authorization !== 'Bearer abs-key') return text(res, 401, 'Unauthorized');
  if (p === '/api/me') return json(res, 200, { id: 'u', username: 'root', type: 'root' });
  if (p === '/api/libraries' && url.searchParams.get('include') === 'stats') return json(res, 200, { libraries: [{ id: 'a1', name: 'Audiobooks', mediaType: 'book', lastScan: 1790000000000, stats: { totalItems: 318, totalSize: 402000000000, totalDuration: 3900000.5, numAudioFiles: 900 } }] });
  if (p === '/api/tasks') return json(res, 200, { tasks: [{ id: 't1', action: 'library-scan', title: 'Scanning Audiobooks', isFailed: false, isFinished: false }] });
  if (p === '/api/libraries/a1/items') {
    if (url.searchParams.get('filter') === 'issues') return json(res, 200, { results: [{ id: 'x1', libraryId: 'a1', isMissing: true, isInvalid: false, path: '/audiobooks/Gone', media: { metadata: { title: 'Gone Book' } } }], total: 1, limit: 10, page: 0 });
    if (url.searchParams.get('sort') === 'addedAt' && url.searchParams.get('desc') === '1') return json(res, 200, { results: [{ id: 'r1', libraryId: 'a1', addedAt: 1790000000000, media: { metadata: { title: 'New Book', authorName: 'Author' }, duration: 3600 } }], total: 318, limit: 5, page: 0 });
  }
  if (p === '/api/sessions/open') return json(res, 200, { sessions: [{ id: 'ps1', displayTitle: 'New Book', displayAuthor: 'Author', duration: 3600, currentTime: 900, playMethod: 2, mediaPlayer: 'html5', deviceInfo: { clientName: 'Abs Web', osName: 'macOS' }, user: { id: 'u', username: 'jordan' } }], shareSessions: [] });
  if (p === '/api/libraries/a1/scan' && req.method === 'POST') { record(`abs scan a1 force=${url.searchParams.get('force')}`); return text(res, 200, 'OK'); }
  if (p === '/api/libraries/a1/issues' && req.method === 'DELETE') { record('abs remove issues a1'); return text(res, 200, 'OK'); }
  if (p === '/api/backups' && req.method === 'GET') return json(res, 200, { backups: [{ id: 'b1', backupDirPath: '/metadata/backups', filename: '2026-09-20T0100.audiobookshelf', fullPath: '/metadata/backups/2026-09-20T0100.audiobookshelf', path: 'backups/2026-09-20T0100.audiobookshelf', fileSize: 21000000, createdAt: 1758330000000, serverVersion: '2.36.0' }], backupLocation: '/metadata/backups', backupPathEnvSet: false });
  if (p === '/api/backups' && req.method === 'POST') { record('abs backup'); return json(res, 200, { backups: [] }); }
  return text(res, 404, 'Not Found');
}

async function immich(req, res, url) {
  const p = url.pathname.replace('/immich/api', '');
  if (p === '/server/version') return json(res, 200, { major: 3, minor: 2, patch: 4, prerelease: null });
  if (req.headers['x-api-key'] !== 'immich-key') return json(res, 401, { message: 'Invalid API key', error: 'Unauthorized', statusCode: 401 });
  if (p === '/server/storage') return json(res, 200, { diskAvailable: '1 TiB', diskAvailableRaw: 1319413953331, diskSize: '3.6 TiB', diskSizeRaw: 3958241859993, diskUsagePercentage: 66.67, diskUse: '2.4 TiB', diskUseRaw: 2638827906662 });
  if (p === '/server/statistics') return json(res, 200, { photos: 12000, videos: 800, usage: 512000000000, usagePhotos: 1, usageVideos: 1, usageByUser: [{ userId: 'u1', userName: 'Alice', photos: 12000, videos: 800, usage: 512000000000, quotaSizeInBytes: null }] });
  if (p === '/jobs' && req.method === 'GET') return json(res, 200, { thumbnailGeneration: { jobCounts: { active: 1, completed: 0, failed: 2, delayed: 0, waiting: 42, paused: 0 }, queueStatus: { isActive: true, isPaused: false } }, backgroundTask: { jobCounts: { active: 0, completed: 0, failed: 0, delayed: 0, waiting: 0, paused: 0 }, queueStatus: { isActive: false, isPaused: false } } });
  const job = p.match(/^\/jobs\/(\w+)$/);
  if (job && req.method === 'PUT') { const b = JSON.parse(await readBody(req)); record(`immich ${job[1]} ${b.command} force=${b.force}`); return json(res, 200, { jobCounts: {}, queueStatus: {} }); }
  if (p === '/server/version-check') return json(res, 200, { checkedAt: '2026-09-29T08:00:00.000Z', releaseVersion: 'v3.3.0' });
  if (p === '/admin/database-backups') return json(res, 200, { backups: [{ filename: 'immich-db-backup-a.sql.gz', filesize: 412000000, timezone: 'UTC' }] });
  return json(res, 404, {});
}

async function wizarr(req, res, url) {
  if (req.headers['x-api-key'] !== 'wizarr-key') return json(res, 401, { error: 'Unauthorized' });
  const p = url.pathname.replace('/wizarr/api', '');
  if (p === '/status') return json(res, 200, { users: 2, invites: 3, pending: 1, expired: 1 });
  if (p === '/invitations' && req.method === 'GET') return json(res, 200, { invitations: [{ id: 5, code: 'ABC123XYZ', url: '/j/ABC123XYZ', status: 'pending', created: '2026-09-01T12:00:00', expires: '2026-10-08T12:00:00', used_at: null, used_by: null, duration: '30', unlimited: false, server_names: ['Home Plex'] }], count: 1 });
  if (p === '/servers') return json(res, 200, { servers: [{ id: 1, name: 'Home Plex', server_type: 'plex', verified: false }], count: 1 });
  if (p === '/users') return json(res, 200, { users: [{ id: 12, username: 'alice', email: 'alice@example.com', server: 'Home Plex', server_type: 'plex', expires: null, created_at: '2026-06-01T10:00:00' }], count: 1 });
  if (p === '/invitations/5' && req.method === 'DELETE') { record('wizarr delete invitation 5'); return json(res, 200, { message: 'Invitation deleted' }); }
  if (p === '/users/12/extend' && req.method === 'POST') { const b = JSON.parse(await readBody(req)); record(`wizarr extend 12 days=${b.days}`); return json(res, 200, { message: 'ok', new_expiry: '2026-12-01T00:00:00' }); }
  return json(res, 404, { message: 'not found' });
}

async function glances(req, res, url) {
  if (req.headers.authorization !== basic('glances', 'glances-pw')) { res.writeHead(401, { 'WWW-Authenticate': 'Basic' }); return res.end(JSON.stringify({ detail: 'Not authenticated' })); }
  const p = url.pathname.replace('/glances/api/4', '');
  const routes = {
    '/pluginslist': ['alert', 'cpu', 'fs', 'load', 'mem', 'quicklook', 'sensors', 'system', 'uptime', 'version'],
    '/version': '4.5.7',
    '/system': { hostname: 'atlas', hr_name: 'Debian 13 64bit', os_name: 'Linux', platform: '64bit' },
    '/uptime': '3 days, 4:05:06',
    '/quicklook': { cpu: 14.3, mem: 39.9, swap: 0.0, load: 4.9, cpu_name: 'Fixture CPU', percpu: [] },
    '/mem': { total: 16417832960, used: 6555460504, available: 9862372456, percent: 39.9 },
    '/load': { cpucore: 16, min1: 0.28, min5: 0.66, min15: 0.78 },
    '/fs': [{ device_name: '/dev/sda1', fs_type: 'ext4', key: 'mnt_point', mnt_point: '/', size: 1000, used: 950, free: 50, percent: 95.0 }],
    '/sensors': [{ label: 'Package id 0', type: 'temperature_core', unit: 'C', value: 81, warning: 80, critical: 95, key: 'label' }, { label: 'sdb', type: 'temperature_hdd', unit: 'C', value: 'ERR', warning: null, critical: null, key: 'label' }],
    '/alert': [{ begin: 1727600000, end: -1, state: 'CRITICAL', type: 'FS', min: 90, max: 95, sum: 185, count: 2, avg: 92.5, top: [], desc: '', sort: null, global_msg: 'High file system usage' }],
    '/quicklook/views': { cpu: { decoration: 'OK', optional: false }, mem: { decoration: 'CAREFUL' }, swap: { decoration: 'OK' }, load: { decoration: 'OK' } },
    '/fs/views': { '/': { used: { decoration: 'CRITICAL_LOG' }, free: { decoration: 'DEFAULT' } } },
    '/sensors/views': { 'Package id 0': { value: { decoration: 'WARNING' } }, show_pod_name: false },
  };
  if (req.method === 'POST' && p === '/events/clear/warning') { record('glances clear warning'); return json(res, 200, {}); }
  if (p in routes) return json(res, 200, routes[p]);
  return json(res, 400, { detail: `Unknown plugin ${p}` });
}

function crowdsec(req, res, url) {
  const p = url.pathname.replace('/crowdsec', '');
  if (p === '/health') return json(res, 200, { status: 'up' });
  if (req.headers['x-api-key'] !== 'cs-key') return json(res, 403, { message: 'access forbidden' });
  if (req.headers['user-agent'] !== 'EnveHomelab/1.0') return json(res, 400, { message: `unexpected user agent ${req.headers['user-agent']}` });
  if (p === '/v1/decisions') {
    if (url.searchParams.get('origins') !== 'crowdsec,cscli,console') return json(res, 400, { message: 'origins expected' });
    return json(res, 200, [{ duration: '3h51m57.363171728s', id: 2336, origin: 'cscli', scenario: "manual 'ban' from 'admin'", scope: 'Ip', type: 'ban', value: '192.168.1.1' }]);
  }
  return json(res, 404, { message: 'not found' });
}


const synologyLogins = { DownloadStation: 0, default: 0 };
async function synology(req, res, url) {
  const p = url.pathname.replace('/synology/webapi/', '');
  const ok = (data) => json(res, 200, { success: true, data });
  const fail = (code) => json(res, 200, { success: false, error: { code } });
  if (p !== 'entry.cgi') return text(res, 404, '');
  const params = req.method === 'POST' ? new URLSearchParams(await readBody(req)) : url.searchParams;
  const api = params.get('api');
  if (api === 'SYNO.API.Info') return ok({
    'SYNO.API.Auth': { path: 'entry.cgi', minVersion: 1, maxVersion: 7 },
    'SYNO.DownloadStation.Task': { path: 'entry.cgi', minVersion: 1, maxVersion: 1 },
    'SYNO.DownloadStation.Info': { path: 'entry.cgi', minVersion: 1, maxVersion: 1 },
    'SYNO.DownloadStation.Statistic': { path: 'entry.cgi', minVersion: 1, maxVersion: 1 },
    'SYNO.Virtualization.API.Guest': { path: 'entry.cgi', minVersion: 1, maxVersion: 1 },
    'SYNO.Virtualization.API.Guest.Action': { path: 'entry.cgi', minVersion: 1, maxVersion: 1 },
    'SYNO.Virtualization.API.Host': { path: 'entry.cgi', minVersion: 1, maxVersion: 1 },
  });
  if (api === 'SYNO.API.Auth') {
    if (req.method !== 'POST' || url.search.includes('passwd')) return fail(101);
    if (params.get('account') !== 'app-user') return fail(400);
    if (params.get('passwd') === 'two-factor') return fail(403);
    if (params.get('passwd') !== 'syno-pass' || params.get('version') !== '6' || params.get('format') !== 'sid') return fail(400);
    const session = params.get('session') ?? 'default';
    synologyLogins[session] = (synologyLogins[session] ?? 0) + 1;
    return ok({ sid: `${session}-${synologyLogins[session]}`, did: '', is_portal_port: false });
  }
  const sid = params.get('_sid') ?? '';
  if (api.startsWith('SYNO.DownloadStation.')) {
    if (!sid.startsWith('DownloadStation-')) return fail(105);
    if (sid === 'DownloadStation-1') return fail(119);
    if (api === 'SYNO.DownloadStation.Info') return ok({ is_manager: true, version: 4760, version_string: '4.0.1-4760' });
    if (api === 'SYNO.DownloadStation.Statistic') return ok({ speed_download: 2048, speed_upload: 16 });
    if (params.get('method') === 'list') return ok({ total: 1, offset: 0, tasks: [{ id: 'dbid_1', type: 'bt', username: 'app-user', title: 'debian.iso', size: '1000', status: 'downloading', status_extra: null, additional: { transfer: { size_downloaded: '500', size_uploaded: '0', speed_download: '100', speed_upload: '0' } } }] });
    record(`synology task ${params.get('method')} ${params.get('id')} force_complete=${params.get('force_complete')}`);
    return ok([{ id: params.get('id'), error: params.get('id') === 'dbid_9' ? 404 : 0 }]);
  }
  if (!sid.startsWith('default-')) return fail(119);
  if (api === 'SYNO.Virtualization.API.Guest') return ok({ guests: [{ guest_id: 'g1', guest_name: 'ha-os', status: 'running', vcpu_num: 2, vram_size: 4096, storage_name: 'volume1', autorun: 1, vdisks: [], vnics: [] }] });
  if (api === 'SYNO.Virtualization.API.Host') return ok({ hosts: [{ host_id: 'h1', host_name: 'ds', status: 'running', total_cpu_core: 4, free_cpu_core: 2, total_ram_size: 8192, free_ram_size: 4096 }] });
  if (api === 'SYNO.Virtualization.API.Guest.Action') { record(`synology vm ${params.get('method')} ${params.get('guest_id')}`); return ok({}); }
  return fail(102);
}

async function dockhand(req, res, url) {
  if (req.headers.authorization !== 'Bearer dh_fixture') return json(res, 401, { error: 'Unauthorized' });
  const p = decodeURIComponent(url.pathname.replace('/dockhand/api', ''));
  if (p === '/environments') return json(res, 200, [{ id: 1, name: 'Tower', connectionType: 'socket' }]);
  if (url.searchParams.get('env') !== '1') return json(res, 400, { error: 'No environment specified' });
  if (p === '/containers' && url.searchParams.get('all') === 'true') return json(res, 200, [
    { id: 'c1', name: 'vaultwarden', image: 'vaultwarden/server', state: 'running', status: 'Up 3 days (healthy)', health: 'healthy', restartCount: 0 },
    { id: 'c2', name: 'probe', image: 'probe', state: 'running', status: 'Up 1 hour (unhealthy)', health: 'unhealthy', restartCount: 3 },
  ]);
  if (p === '/stacks') return json(res, 200, [{ name: 'media stack', status: 'running', containers: ['web'] }]);
  const action = p.match(/^\/(containers|stacks)\/(.+)\/(start|stop|restart)$/);
  if (action && req.method === 'POST') {
    record(`dockhand ${action[1]} ${action[2]} ${action[3]}`);
    if (action[1] === 'stacks' && action[3] === 'stop') return json(res, 200, { success: false, error: 'compose stop failed' });
    return json(res, 200, { success: true });
  }
  return json(res, 404, { error: 'Not found' });
}

let komodoPolls = 0;
async function komodo(req, res, url) {
  if (req.headers['x-api-key'] !== 'K_fixture_K' || req.headers['x-api-secret'] !== 'S_fixture_S') return json(res, 401, { error: 'Invalid user credentials', trace: [] });
  if (req.headers.authorization) return json(res, 401, { error: 'Authorization must not be sent with an API key', trace: [] });
  const body = JSON.parse(await readBody(req));
  const p = url.pathname.replace('/komodo', '');
  if (p === '/read') {
    switch (body.type) {
      case 'GetVersion': return json(res, 200, { version: '2.3.3' });
      case 'ListServers': return json(res, 200, [{ id: 's1', type: 'Server', name: 'tower', template: false, tags: [], info: { state: 'Ok', region: 'home', version: '2.3.3', stats: { cpu_perc: 12.5, mem_used_gb: 8, mem_total_gb: 32 } } }, { id: 's2', type: 'Server', name: 'pi', template: false, tags: [], info: { state: 'NotOk', region: '' } }]);
      case 'ListStacks': return json(res, 200, [{ id: 'st1', type: 'Stack', name: 'media', template: false, tags: [], info: { state: 'running', status: 'Up 2 days', server_id: 's1', server_name: 'tower', services: [{ service: 'web', image: 'nginx', update_available: true }] } }]);
      case 'ListDeployments': return json(res, 200, [{ id: 'd1', type: 'Deployment', name: 'proxy', template: false, tags: [], info: { state: 'not_deployed', image: 'caddy', update_available: false, server_id: 's1' } }]);
      case 'ListAlerts': return json(res, 200, { alerts: [{ level: 'CRITICAL', ts: 1790000000000, resolved: false, data: { type: 'ServerUnreachable', data: { id: 's2', name: 'pi', err: { error: 'timeout', trace: [] } } } }], next_page: null });
      case 'GetUpdate': komodoPolls += 1; return json(res, 200, body.params.id === 'u-denied'
        ? { status: 'Complete', success: false, logs: [{ stage: 'Task Error', stderr: 'User does not have Execute permission on Stack', success: false }] }
        : { status: komodoPolls > 1 ? 'Complete' : 'InProgress', success: true, logs: [] });
      default: return json(res, 500, { error: `unknown ${body.type}`, trace: [] });
    }
  }
  if (p === '/execute') {
    record(`komodo ${body.type} ${JSON.stringify(body.params)}`);
    komodoPolls = 0;
    return json(res, 200, { _id: { $oid: body.type === 'StopStack' ? 'u-denied' : 'u-1' }, status: 'InProgress', success: false, operation: body.type });
  }
  return json(res, 404, { error: 'not found', trace: [] });
}

async function coolify(req, res, url) {
  const p = url.pathname.replace('/coolify/api/v1', '');
  if (req.headers.authorization !== 'Bearer 1|coolify-token') return json(res, 401, { message: 'Unauthenticated.' });
  if (p === '/version') return text(res, 200, '4.3.23');
  if (p === '/servers') return json(res, 200, [{ uuid: 'srv1', name: 'localhost', ip: 'host.docker.internal', port: 22, user: 'root', is_reachable: true, is_usable: true, settings: {} }]);
  if (p === '/applications') return json(res, 200, [{ uuid: 'app1', name: 'site', status: 'running:healthy', fqdn: 'https://site.example,https://www.site.example', server_status: true }]);
  if (p === '/services') return json(res, 200, [{ uuid: 'svc1', name: 'plausible', status: 'degraded:unhealthy', service_type: 'plausible' }]);
  if (p === '/databases') return json(res, 200, [{ uuid: 'db1', name: 'pg', status: 'exited', database_type: 'standalone-postgresql' }]);
  if (p === '/deployments') return json(res, 200, { 1: { deployment_uuid: 'dep2', application_name: 'site', status: 'in_progress' }, 0: { deployment_uuid: 'dep1', application_name: 'api', status: 'queued' } });
  if (req.method !== 'POST') return json(res, 405, { message: 'This endpoint has changed to a POST request.' });
  record(`coolify ${p}${url.search}`);
  if (p === '/deploy') return json(res, 200, { deployments: [{ message: 'queued', resource_uuid: url.searchParams.get('uuid'), deployment_uuid: 'dep3' }] });
  if (p.endsWith('/cancel')) return json(res, 200, { message: 'Deployment cancelled successfully.', status: 'cancelled-by-user' });
  return json(res, 200, { message: 'Request queued.' });
}

async function arcane(req, res, url) {
  const p = url.pathname.replace('/arcane/api', '');
  if (p === '/app-version') return json(res, 200, { currentVersion: '2.14.0', displayVersion: 'v2.14.0', revision: 'abc', updateAvailable: false });
  if (req.headers['x-api-key'] !== 'arc_fixture') return json(res, 401, { title: 'Unauthorized', status: 401, detail: 'Unauthorized: invalid API key' });
  const page = (data) => json(res, 200, { success: true, data, pagination: { totalPages: 1, totalItems: data.length, currentPage: 1, itemsPerPage: 200 } });
  if (p === '/environments') return page([{ id: '0', name: 'Local', apiUrl: 'http://localhost', status: 'online', enabled: true, isEdge: false }, { id: 'env-2', name: 'Pi', apiUrl: 'http://pi', status: 'online', enabled: true, isEdge: false }, { id: 'env-3', status: 'offline', apiUrl: '', enabled: false, isEdge: false }]);
  if (p.startsWith('/environments/env-2/')) return json(res, 403, { title: 'Forbidden', status: 403, detail: 'API key lacks containers:list for this environment' });
  if (p === '/environments/0/containers') return page([{ id: 'a1', names: ['/immich_server'], image: 'immich', imageId: 'x', command: '', created: 1, ports: [], labels: {}, state: 'running', status: 'Up 5 days (healthy)', hostConfig: {}, networkSettings: {}, mounts: [], autoUpdateEnabled: false }]);
  if (p === '/environments/0/projects') return page([{ id: 'p1', name: 'immich', path: '/x', status: 'partially running', runningCount: 2, serviceCount: 3, isArchived: false, tags: [], createdAt: '', updatedAt: '', envContent: 'DB_PASSWORD=secret', composeContent: 'services: {}' }]);
  if (p === '/environments/0/projects/p1/up' && req.method === 'POST') {
    record('arcane project up p1');
    res.writeHead(200, { 'Content-Type': 'application/x-ndjson' });
    return res.end('{"status":"pulling"}\n{"error":"port 2283 already allocated"}\n');
  }
  const action = p.match(/^\/environments\/0\/(containers|projects)\/(\w+)\/(restart|stop|start|down)$/);
  if (action && req.method === 'POST') { record(`arcane ${action[1]} ${action[2]} ${action[3]}`); return json(res, 200, { success: true, data: { message: 'ok' } }); }
  return json(res, 404, { title: 'Not Found', status: 404 });
}

let beszelLogins = 0;
async function beszel(req, res, url) {
  const p = url.pathname.replace('/beszel', '');
  if (p === '/api/collections/users/auth-with-password' && req.method === 'POST') {
    const body = JSON.parse(await readBody(req));
    if (body.identity === 'mfa@example.com') return json(res, 401, { mfaId: 'mfa-1' });
    if (body.identity !== 'app@example.com' || body.password !== 'beszel-pass') return json(res, 400, { status: 400, message: 'Failed to authenticate.', data: {} });
    beszelLogins += 1;
    return json(res, 200, { token: `pb-${beszelLogins}`, record: { id: 'u1', email: body.identity, role: 'user' } });
  }
  // The first token is treated as expired to exercise re-authentication.
  const auth = req.headers.authorization ?? '';
  if (auth === 'pb-1' || auth !== `pb-${beszelLogins}`) return json(res, 401, { status: 401, message: 'The request requires valid record authorization token.', data: {} });
  if (p === '/api/beszel/info') return json(res, 200, { key: 'ssh-ed25519 AAAA', v: '0.20.0', cu: false });
  if (p === '/api/collections/systems/records' && req.method === 'GET') return json(res, 200, { page: 1, perPage: 500, items: [{ id: 'sys1', name: 'tower', status: 'up', host: '10.0.0.2', port: '45876', info: { u: 3600, cpu: 7.5, mp: 41.2, dp: 63, v: '0.20.0', la: [0.5, 0.7, 0.9], sv: [40, 2] } }, { id: 'sys2', name: 'pi', status: 'down', host: '10.0.0.3', info: {} }] });
  if (p === '/api/collections/containers/records') return json(res, 200, { page: 1, perPage: 500, items: [{ id: 'c1', name: 'zigbee', system: 'sys1', status: 'Up 2 hours', health: 3, cpu: 1.5, memory: 120, updated: 1790000000000 }] });
  if (p === '/api/collections/alerts/records') return json(res, 200, { page: 1, perPage: 500, items: url.searchParams.get('filter') === 'triggered=true' ? [{ id: 'al1', name: 'Status', system: 'sys2', triggered: true }] : [] });
  if (p === '/api/collections/systems/records/sys2' && req.method === 'PATCH') { record(`beszel ${JSON.parse(await readBody(req)).status} sys2`); return json(res, 200, { id: 'sys2' }); }
  return json(res, 404, { status: 404, message: 'Missing collection context.' });
}

async function technitium(req, res, url) {
  const form = new URLSearchParams(await readBody(req));
  const reply = (response) => json(res, 200, { status: 'ok', response, server: 'server1' });
  if (form.get('token') !== 'tech-token' || req.headers.authorization !== 'Bearer tech-token') return json(res, 200, { status: 'invalid-token', errorMessage: 'Invalid token or session expired.' });
  if (req.method !== 'POST' || url.search.includes('token')) return json(res, 200, { status: 'error', errorMessage: 'token must be sent in the body' });
  const p = url.pathname.replace('/technitium/api/', '');
  if (p === 'settings/get') return reply({ version: '15.5.1', enableBlocking: false, temporaryDisableBlockingTill: new Date(Date.now() + 600000).toISOString(), proxy: { password: 'never-decoded' } });
  if (p === 'dashboard/stats/get') return reply({ stats: { totalQueries: 925, totalBlocked: 49, totalCached: 481, totalClients: 6, blockListZones: 307447 }, topClients: [] });
  if (p === 'settings/temporaryDisableBlocking') { record(`technitium pause ${form.get('minutes')}`); return reply({ temporaryDisableBlockingTill: new Date().toISOString() }); }
  if (p === 'settings/set') { record(`technitium set enableBlocking=${form.get('enableBlocking')} keys=${[...form.keys()].sort().join(',')}`); return reply({}); }
  return json(res, 200, { status: 'error', errorMessage: 'No such API' });
}

async function controld(req, res, url) {
  if (req.headers.authorization !== 'Bearer cd-token') return json(res, 401, { body: [], success: false, error: { message: 'Invalid API token', code: 40101 } });
  const p = url.pathname.replace('/controld', '');
  if (p === '/profiles') return json(res, 200, { body: { profiles: [{ PK: 'p1', updated: 1, name: 'Family', stats: 0, profile: { flt: { count: 3 }, da: [] } }] }, success: true });
  if (p === '/devices') return json(res, 200, { body: { devices: [{ PK: 'd1', name: 'Router', status: 1, stats: 2, device_id: 'd1', profile: { PK: 'p1', name: 'Family' }, resolvers: { uid: 'd1' } }, { PK: 'd2', name: 'Tablet', status: 3, profile: { PK: 'p1', name: 'Family' } }] }, success: true });
  if (p === '/profiles/p1' && req.method === 'PUT') { record(`controld p1 disable_ttl=${new URLSearchParams(await readBody(req)).get('disable_ttl') === '0' ? '0' : 'future'}`); return json(res, 200, { body: { profiles: [] }, success: true }); }
  return json(res, 404, { body: [], success: false, error: { message: 'Not found', code: 40400 } });
}

async function nextdns(req, res, url) {
  if (req.headers['x-api-key'] !== 'nd-key') return json(res, 403, { errors: [{ code: 'forbidden', detail: 'Invalid API key' }] });
  const p = url.pathname.replace('/nextdns/profiles/abc123', '');
  const day = url.searchParams.get('from') === '-24h';
  if (p === '') return json(res, 200, { data: { name: 'Home', settings: { logs: { enabled: true } } } });
  if (!day && req.method === 'GET') return json(res, 400, { errors: [{ code: 'invalid', detail: 'from expected', source: { parameter: 'from' } }] });
  if (p === '/analytics/status') return json(res, 200, { data: [{ status: 'default', queries: 800 }, { status: 'blocked', queries: 200 }], meta: { pagination: { cursor: null } } });
  if (p === '/analytics/domains' && url.searchParams.get('status') === 'blocked') return json(res, 200, { data: [{ domain: 'ads.example.com', root: 'example.com', queries: 120 }], meta: {} });
  if (p === '/analytics/reasons') return json(res, 200, { data: [{ id: 'blocklist:oisd', name: 'oisd', queries: 180 }], meta: {} });
  if (p === '/analytics/devices') return json(res, 200, { data: [{ id: 'D1', name: 'Phone', queries: 700 }, { id: '__UNIDENTIFIED__', queries: 300 }], meta: {} });
  if (p === '/allowlist' && req.method === 'POST') {
    const body = JSON.parse(await readBody(req));
    record(`nextdns allow ${body.id} active=${body.active}`);
    if (body.id.includes('..')) return json(res, 200, { errors: [{ code: 'invalid', detail: 'Invalid domain' }] });
    return json(res, 200, { data: body });
  }
  return json(res, 404, { errors: [{ code: 'notFound' }] });
}

async function gluetun(req, res, url) {
  const p = url.pathname.replace('/gluetun', '');
  if (req.headers['x-api-key'] !== 'glu-key') return text(res, 401, 'Unauthorized');
  if (p === '/v1/publicip/ip') return text(res, 401, 'Unauthorized');
  if (p === '/v1/version') return json(res, 200, { version: 'v3.40.0', commit: 'abc', created: '' });
  if (p === '/v1/vpn/status' && req.method === 'GET') return json(res, 200, { status: 'running' });
  if (p === '/v1/vpn/status' && req.method === 'PUT') { record(`gluetun vpn ${JSON.parse(await readBody(req)).status}`); return json(res, 200, { outcome: 'stopped' }); }
  if (p === '/v1/portforward') return text(res, 404, '404 page not found');
  if (p === '/v1/openvpn/portforwarded') return json(res, 200, { port: 5914 });
  if (p === '/v1/dns/status') return json(res, 200, { status: 'running' });
  if (p === '/v1/updater/status') return json(res, 200, { status: 'completed' });
  return text(res, 404, 'not found');
}

async function qui(req, res, url) {
  if (req.headers['x-api-key'] !== 'qui-key') return text(res, 401, 'Unauthorized');
  const p = url.pathname.replace('/qui/api', '');
  if (p === '/version') return json(res, 200, { version: 'v1.8.0', updateAvailable: false });
  if (p === '/instances') return json(res, 200, [
    { id: 1, name: 'seedbox', isActive: true, connected: true, connectionError: '' },
    { id: 2, name: 'old-box', isActive: true, connected: false, connectionError: 'timeout' },
    { id: 3, name: 'retired', isActive: false, connected: false },
  ]);
  if (p === '/instances/1/transfer-info') return json(res, 200, { connection_status: 'connected', dl_info_speed: 4096, up_info_speed: 128 });
  if (p === '/instances/1/torrents') {
    if (url.searchParams.get('limit') !== '200') return json(res, 400, { error: 'limit expected' });
    return json(res, 200, { torrents: [{ hash: 'h1', name: 'debian.iso', size: 100, progress: 0.5, dlspeed: 4096, upspeed: 0, eta: 60, state: 'downloading', category: 'iso', amount_left: 50 }], total: 1 });
  }
  if (p === '/instances/1/torrents/bulk-action' && req.method === 'POST') {
    const body = JSON.parse(await readBody(req));
    if (body.selectAll) return json(res, 400, { error: 'selectAll must never be sent' });
    record(`qui ${body.action} ${body.hashes.join(',')} deleteFiles=${body.deleteFiles}`);
    return text(res, 200, 'Action performed successfully');
  }
  return json(res, 404, { error: 'not found' });
}

async function tracearr(req, res, url) {
  const auth = req.headers.authorization ?? '';
  if (!auth.startsWith('Bearer trr_pub_')) return json(res, 401, { error: 'Invalid API key format' });
  if (auth !== 'Bearer trr_pub_fixture') return json(res, 401, { error: 'Invalid API key' });
  const p = url.pathname.replace('/tracearr/api/v1/public', '');
  if (p === '/health') return json(res, 200, { status: 'ok', version: '2.5.1', timestamp: '', servers: [{ id: 's1', name: 'Main Plex', type: 'plex', online: true, activeStreams: 1 }, { id: 's2', name: 'Jellyfin', type: 'jellyfin', online: false, activeStreams: 0 }] });
  if (p === '/stats/today') return json(res, 200, { activeStreams: 1, todayPlays: 47, watchTimeHours: 12.5, alertsLast24h: 3, activeUsersToday: 8 });
  if (p === '/activity') {
    if (url.searchParams.get('period') !== 'week') return json(res, 400, { error: 'period expected' });
    return json(res, 200, { period: 'week', range: { start: '2026-09-22', end: '2026-09-29' }, plays: [], concurrent: [{ date: '2026-09-28 00:00:00', total: 6, direct: 3, directStream: 1, transcode: 2 }, { date: '2026-09-29 00:00:00', total: 4, direct: 2, directStream: 0, transcode: 3 }],
      byDayOfWeek: [], byHourOfDay: [], platforms: [], quality: { directPlay: 60, directStream: 10, transcode: 30, total: 100, directPlayPercent: 60, directStreamPercent: 10, transcodePercent: 30 } });
  }
  if (p === '/streams') return json(res, 200, { data: [{ transcodeInfo: { containerDecision: 'transcode', sourceContainer: 'mkv', streamContainer: 'mpegts', hwRequested: true, speed: 0.7, throttled: false, reasons: ['Audio codec not supported'] }, id: 'st-1', serverName: 'Main Plex', username: 'guest', mediaTitle: 'Sermon', mediaType: 'episode', showTitle: 'Pioneer One', seasonNumber: 1, episodeNumber: 4, state: 'playing', progressMs: 600000, durationMs: 2400000, isTranscode: true, videoDecision: 'transcode', bitrate: 4200, resolution: '720p', player: 'Chrome' }] });
  if (p === '/violations' && url.searchParams.get('acknowledged') === 'false') return json(res, 200, { data: [{ id: 'v1', serverId: 's1', serverName: 'Main Plex', severity: 'high', acknowledged: false, data: {}, createdAt: '2026-09-29T10:00:00.000Z', rule: { id: 'r', type: null, name: 'Impossible travel' }, user: { id: 'u', username: 'guest' } }], meta: { total: 1, page: 1, pageSize: 25 } });
  const terminate = p.match(/^\/streams\/([\w-]+)\/terminate$/);
  if (terminate && req.method === 'POST') { const body = JSON.parse(await readBody(req)); record(`tracearr terminate ${terminate[1]} reason=${body.reason}`); return json(res, 200, { success: true, sessionId: terminate[1], message: 'Session terminated successfully' }); }
  return json(res, 404, { error: 'Not found' });
}

async function dispatcharr(req, res, url) {
  const p = url.pathname.replace('/dispatcharr', '');
  // Django redirects slash-less paths; failing here instead proves the client keeps the slash.
  if (!p.endsWith('/')) return json(res, 400, { detail: 'missing trailing slash' });
  if (p === '/api/core/version/') return json(res, 200, { version: '0.31.0', timestamp: null });
  if (req.headers['x-api-key'] !== 'disp-key') return json(res, 401, { detail: 'Invalid API key' });
  if (p === '/api/m3u/accounts/') return json(res, 200, [{ id: 1, name: 'Tuner', is_active: true, status: 'error', last_message: 'Download timed out', updated_at: '2026-09-28T10:00:00Z', server_url: 'http://provider.example/get.php?username=u&password=p', username: 'u', password: 'p' }]);
  if (p === '/api/epg/sources/') return json(res, 200, [{ id: 1, name: 'Guide', source_type: 'xmltv', url: 'http://provider.example/xmltv', is_active: true, status: 'success', updated_at: '2026-09-29T10:00:00Z' }]);
  if (p === '/proxy/stats/') return json(res, 500, { error: 'Redis not available' });
  if (p === '/api/core/system-events/') return json(res, 200, { events: url.searchParams.get('event_type') === 'm3u_error' ? [{ id: 9, event_type: 'm3u_error', event_type_display: 'M3U Error', timestamp: new Date().toISOString(), channel_name: 'never-shown', details: { ip: '10.0.0.9' } }] : [], count: 1, total: 1, offset: 0, limit: 50 });
  if (p === '/api/backups/' && req.method === 'GET') return json(res, 200, [{ name: 'dispatcharr-backup-2026.09.28.zip', size: 18400000, created: '2026-09-28T02:00:00+00:00' }, { name: 'dispatcharr-backup-2026.09.20.zip', size: 18000000, created: '2026-09-20T02:00:00+00:00' }]);
  if (p === '/api/backups/schedule/') return json(res, 200, { enabled: true, frequency: 'daily', time: '02:00', day_of_week: 0, retention_count: 7, cron_expression: '' });
  if (p === '/api/backups/create/' && req.method === 'POST') { dispatcharrBackups += 1; record(`dispatcharr backup ${dispatcharrBackups}`); return json(res, 202, { detail: 'Backup started', task_id: `task-${dispatcharrBackups}`, task_token: `tok-${dispatcharrBackups}` }); }
  const backupStatus = p.match(/^\/api\/backups\/status\/(task-\d+)\/$/);
  if (backupStatus) {
    const n = Number(backupStatus[1].split('-')[1]);
    if (url.searchParams.get('token') !== `tok-${n}`) return json(res, 403, { detail: 'Invalid task token' });
    // Odd-numbered backups succeed, even-numbered ones fail, so both paths are exercised.
    return json(res, 200, n % 2 === 1 ? { state: 'completed', result: { status: 'completed', filename: 'x.zip', size: 1 } } : { state: 'failed', error: 'No space left on device' });
  }
  return json(res, 404, { detail: 'Not found.' });
}

const seerr = {
  requests: [
    { id: 41, status: 1, type: 'movie', media: { id: 90, tmdbId: 603, status: 2 }, createdAt: '2026-09-28T10:00:00.000Z', is4k: false,
      requestedBy: { id: 3, displayName: 'Jordan', email: 'jordan@example.com', plexToken: 'must-not-be-read' } },
    { id: 40, status: 1, type: 'tv', media: { id: 91, tmdbId: 1399, status: 2 }, createdAt: '2026-09-27T10:00:00.000Z', is4k: false,
      requestedBy: { id: 4, username: 'sam' }, seasons: [{ id: 1, seasonNumber: 2, status: 1 }] },
    { id: 38, status: 4, type: 'movie', media: { id: 92, tmdbId: 604, status: 3 }, createdAt: '2026-09-20T10:00:00.000Z', is4k: false, requestedBy: { id: 3, displayName: 'Jordan' } },
  ],
  issues: [{ id: 7, issueType: 3, status: 1, media: { id: 90, tmdbId: 603, mediaType: 'movie' }, createdBy: { id: 4, username: 'sam' }, createdAt: '2026-09-28T12:00:00.000Z', comments: [{ id: 1, message: 'Subtitles drift' }] }],
};

async function seerrHandler(req, res, url) {
  if (req.headers['x-api-key'] !== 'seerr-key') return json(res, 403, { message: 'You do not have permission to access this endpoint' });
  const p = url.pathname.replace('/seerr/api/v1', '');
  const byID = (id) => seerr.requests.find((r) => r.id === Number(id));
  if (p === '/status') return json(res, 200, { version: '3.0.1', commitTag: 'v3.0.1', updateAvailable: false, commitsBehind: 0, restartRequired: false });
  if (p === '/request/count') return json(res, 200, { total: seerr.requests.length, movie: 2, tv: 1, pending: seerr.requests.filter((r) => r.status === 1).length, approved: 0, declined: 0, processing: 0, available: 0 });
  if (p === '/issue/count') return json(res, 200, { total: 1, video: 0, audio: 0, subtitles: 1, others: 0, open: seerr.issues.filter((i) => i.status === 1).length, closed: 0 });
  if (p === '/settings/about') return json(res, 200, { version: '3.0.1', totalRequests: 12, totalMediaItems: 40, tz: 'UTC', appDataPath: '/app/config' });
  if (p === '/movie/603') return json(res, 200, { id: 603, title: 'Sintel', releaseDate: '2010-09-30' });
  if (p === '/movie/604') return json(res, 500, { message: 'TMDB unavailable' });
  if (p === '/tv/1399') return json(res, 200, { id: 1399, name: 'Pioneer One', firstAirDate: '2010-06-16', seasons: [{ id: 10, seasonNumber: 0, name: 'Specials', episodeCount: 1 }, { id: 11, seasonNumber: 1, name: 'Season 1', episodeCount: 6 }, { id: 12, seasonNumber: 2, name: 'Season 2', episodeCount: 6 }] });
  if (p === '/user' && req.method === 'GET') {
    if (url.searchParams.get('take') === null) return json(res, 400, { message: 'take expected' });
    return json(res, 200, { pageInfo: { pages: 1, pageSize: 100, results: 2, page: 1 }, results: [{ id: 3, displayName: 'Jordan', email: 'jordan@example.com', plexToken: 'must-not-be-read' }, { id: 4, username: 'sam', email: 'sam@example.com' }] });
  }
  if (p === '/user/3/quota') return json(res, 200, { movie: { days: 7, limit: 5, used: 2, remaining: 3, restricted: false }, tv: { days: 7, limit: 0, used: 1, remaining: 0, restricted: false } });
  if (p === '/user/4/quota') return json(res, 403, { message: 'You do not have permission to view this user.' });
  if (p === '/issue/7' && req.method === 'GET') return json(res, 200, seerr.issues.find((i) => i.id === 7));
  if (p === '/issue/7/comment' && req.method === 'POST') {
    const body = JSON.parse(await readBody(req));
    if (!body.message) return json(res, 400, { message: 'message expected' });
    const issue = seerr.issues.find((i) => i.id === 7);
    issue.comments.push({ id: issue.comments.length + 1, message: body.message, user: { id: 1, displayName: 'Owner' }, createdAt: '2026-09-29T12:00:00.000Z' });
    record(`seerr comment 7 ${body.message}`);
    return json(res, 200, issue);
  }
  if (p === '/service/radarr') return json(res, 200, [{ id: 0, name: 'Radarr', is4k: false, isDefault: true, activeDirectory: '/movies', activeProfileId: 4, activeTags: [] }, { id: 2, name: 'Radarr 4K', is4k: true, isDefault: true, activeDirectory: '/movies-4k', activeProfileId: 5, activeTags: [] }]);
  if (p === '/service/radarr/0') return json(res, 200, { server: { id: 0, name: 'Radarr', is4k: false, isDefault: true, activeDirectory: '/movies', activeProfileId: 4 }, profiles: [{ id: 4, name: 'HD-1080p' }, { id: 5, name: 'Ultra-HD' }], rootFolders: [{ id: 1, freeSpace: 100, path: '/movies', totalSpace: 200 }, { id: 2, freeSpace: 100, path: '/kids', totalSpace: 200 }], tags: [] });
  if (p === '/request' && req.method === 'GET') {
    const filter = url.searchParams.get('filter');
    if (url.searchParams.get('take') === null) return json(res, 400, { message: 'take expected' });
    const results = seerr.requests.filter((r) => filter === 'pending' ? r.status === 1 : filter === 'failed' ? r.status === 4 : true);
    return json(res, 200, { pageInfo: { pages: 1, pageSize: 30, results: results.length, page: 1 }, results });
  }
  let m = p.match(/^\/request\/(\d+)$/);
  if (m && req.method === 'PUT') {
    const request = byID(m[1]);
    if (!request) return json(res, 404, { message: 'Request not found.' });
    if (request.status !== 1) return json(res, 409, { message: 'Only pending requests can be modified.' });
    const body = JSON.parse(await readBody(req));
    if (body.mediaType === 'tv' && !(body.seasons ?? []).length) return json(res, 500, { message: 'Missing seasons. If you want to cancel a series request, use the DELETE method.' });
    if (body.userId === 4 && body.mediaType === 'movie') return json(res, 403, { message: 'Movie Quota exceeded.' });
    Object.assign(request, { serverId: body.serverId, profileId: body.profileId, rootFolder: body.rootFolder });
    if (body.seasons) request.seasons = body.seasons.map((n) => ({ seasonNumber: n }));
    record(`seerr route ${request.id} ${body.mediaType} server=${body.serverId} profile=${body.profileId} folder=${body.rootFolder} seasons=${(body.seasons ?? []).join(',')}${body.userId ? ` user=${body.userId}` : ''}`);
    return json(res, 200, request);
  }
  if (m && req.method === 'DELETE') {
    seerr.requests = seerr.requests.filter((r) => r.id !== Number(m[1]));
    record(`seerr delete ${m[1]}`);
    res.writeHead(204); return res.end();
  }
  m = p.match(/^\/request\/(\d+)\/(approve|decline|retry)$/);
  if (m && req.method === 'POST') {
    const request = byID(m[1]);
    if (!request) return json(res, 404, { message: 'Request not found.' });
    if (m[2] === 'retry' ? request.status !== 4 : request.status !== 1) return json(res, 409, { message: m[2] === 'retry' ? 'Only failed requests can be retried.' : 'Only pending requests can be approved or declined.' });
    request.status = m[2] === 'decline' ? 3 : 2;
    record(`seerr ${m[2]} ${request.id}`);
    return json(res, 200, request);
  }
  if (p === '/issue' && req.method === 'GET') {
    const resolved = url.searchParams.get('filter') === 'resolved';
    const results = seerr.issues.filter((i) => (i.status === 2) === resolved);
    return json(res, 200, { pageInfo: { pages: 1, pageSize: 30, results: results.length, page: 1 }, results });
  }
  m = p.match(/^\/issue\/(\d+)\/(open|resolved)$/);
  if (m && req.method === 'POST') {
    const issue = seerr.issues.find((i) => i.id === Number(m[1]));
    issue.status = m[2] === 'resolved' ? 2 : 1;
    record(`seerr issue ${issue.id} ${m[2]}`);
    return json(res, 200, issue);
  }
  return json(res, 404, { message: 'Not found' });
}

// Unraid API GraphQL over HTTP. "/unraid-old" answers like an API release that predates the diagnostics fields.
async function unraidGraphQL(req, res, url) {
  if (req.headers['x-api-key'] !== 'unraid-key') return json(res, 200, { errors: [{ message: 'Unauthorized', extensions: { code: 'UNAUTHENTICATED' } }] });
  const old = url.pathname.startsWith('/unraid-old/');
  const { query, variables = {} } = JSON.parse(await readBody(req));
  const operation = (query.match(/^\s*(?:query|mutation)\s+(\w+)/) ?? [])[1];
  const missing = (field, type) => json(res, 400, { errors: [{ message: `Cannot query field "${field}" on type "${type}".`, extensions: { code: 'GRAPHQL_VALIDATION_FAILED' } }] });
  switch (operation) {
    case 'ContainerDetails':
      if (old) return missing('container', 'Docker');
      if (variables.id !== 'c1') return json(res, 200, { data: { docker: { container: null } } });
      return json(res, 200, { data: { docker: { container: { id: 'c1', templatePath: '/boot/config/plugins/dockerMan/templates-user/my-plex.xml', projectUrl: 'https://www.plex.tv', registryUrl: 'https://hub.docker.com/r/plexinc/pms-docker', supportUrl: 'https://forums.unraid.net', isOrphaned: false, isUpdateAvailable: true, isRebuildReady: false, lanIpPorts: ['192.168.1.20:32400'], sizeRootFs: '2400000000', sizeRw: 1048576, sizeLog: '52428800', autoStart: true, autoStartOrder: 0, autoStartWait: 5 } } } });
    case 'PortConflicts':
      if (old) return missing('portConflicts', 'Docker');
      return json(res, 200, { data: { docker: { portConflicts: { containerPorts: [], lanPorts: [{ lanIpPort: '192.168.1.20:8080', publicPort: 8080, type: 'TCP', containers: [{ id: 'c2', name: 'qbittorrent' }, { id: 'c3', name: 'sabnzbd' }] }] } } } });
    case 'Temperatures':
      if (old) return missing('temperature', 'Metrics');
      return json(res, 200, { data: { metrics: { temperature: { summary: { average: 41.5, warningCount: 0, criticalCount: 1 }, sensors: [
        { id: 'cpu', name: 'CPU Package', type: 'CPU_PACKAGE', location: null, warning: 80, critical: 90, current: { value: 91, unit: 'CELSIUS', status: 'CRITICAL', timestamp: '2026-09-29T10:00:00.000Z' }, min: { value: 35, unit: 'CELSIUS' }, max: { value: 92, unit: 'CELSIUS' }, history: [{ value: 88, unit: 'CELSIUS', timestamp: '2026-09-29T09:55:00.000Z' }, { value: 91, unit: 'CELSIUS', timestamp: '2026-09-29T10:00:00.000Z' }] },
        { id: 'mb', name: 'Motherboard', type: 'MOTHERBOARD', location: null, warning: null, critical: null, current: { value: 30, unit: 'CELSIUS', status: 'NORMAL', timestamp: '2026-09-29T10:00:00.000Z' }, min: null, max: null, history: null }] } } } });
    case 'LogFiles':
      return json(res, 200, { data: { logFiles: [{ name: 'syslog', path: '/var/log/syslog', size: 2048, modifiedAt: '2026-09-29T10:00:00.000Z' }, { name: 'docker.log', path: '/var/log/docker.log', size: 512, modifiedAt: '2026-09-29T09:00:00.000Z' }] } });
    case 'LogFile':
      if (variables.path !== '/var/log/syslog' || typeof variables.lines !== 'number') return json(res, 200, { errors: [{ message: 'path and lines expected' }] });
      record(`unraid logFile ${variables.path} ${variables.lines}`);
      return json(res, 200, { data: { logFile: { path: '/var/log/syslog', content: 'Sep 29 10:00:01 Tower kernel: ata3: hard resetting link\nSep 29 10:00:02 Tower emhttpd: spinning down /dev/sdc\n', totalLines: 9120, startLine: 9119 } } });
    default:
      return json(res, 200, { errors: [{ message: `Fixture has no operation ${operation}` }] });
  }
}

const piholeAllowed = new Set();
let dispatcharrBackups = 0;

const http = createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  try {
    if (url.pathname === '/__log') return json(res, 200, log);
    if (/^\/(radarr|sonarr|lidarr)\//.test(url.pathname)) return await arr(req, res, url);
    if (url.pathname.startsWith('/qbt/')) return await qbittorrent(req, res, url);
    if (url.pathname === '/transmission/rpc') return await transmission(req, res);
    if (url.pathname === '/sab/api') return sabnzbd(req, res, url);
    if (url.pathname.startsWith('/jf/')) return await mediaBrowser(req, res, url, 'jf');
    if (url.pathname.startsWith('/emby/')) return await mediaBrowser(req, res, url, 'emby');
    if (url.pathname.startsWith('/plex')) return await plex(req, res, url);
    if (url.pathname.startsWith('/pve/')) return await proxmox(req, res, url);
    if (url.pathname.startsWith('/portainer/')) return await portainer(req, res, url);
    if (url.pathname.startsWith('/pihole/')) return await pihole(req, res, url);
    if (url.pathname.startsWith('/adguard/')) return await adguard(req, res, url);
    if (url.pathname.startsWith('/unifi/')) return await unifi(req, res, url);
    if (url.pathname.startsWith('/ha/')) return await homeAssistant(req, res, url);
    if (url.pathname.startsWith('/tailscale/')) return tailscale(req, res, url);
    if (url.pathname.startsWith('/cloudflare/')) return cloudflare(req, res, url);
    if (url.pathname.startsWith('/ntfy/')) return await ntfy(req, res, url);
    if (url.pathname === '/nzbget/jsonrpc') return await nzbget(req, res);
    if (url.pathname === '/deluge/json') return await deluge(req, res);
    if (url.pathname.startsWith('/bazarr/')) return await bazarr(req, res, url);
    if (url.pathname.startsWith('/hydra/')) return await hydra(req, res, url);
    if (url.pathname.startsWith('/jackett/')) return jackett(req, res, url);
    if (url.pathname.startsWith('/tdarr/')) return await tdarr(req, res, url);
    if (url.pathname.startsWith('/maintainerr/')) return await maintainerr(req, res, url);
    if (url.pathname === '/tautulli/api/v2') return tautulli(req, res, url);
    if (url.pathname.startsWith('/komga/')) return await komga(req, res, url);
    if (url.pathname.startsWith('/kavita/')) return await kavita(req, res, url);
    if (url.pathname.startsWith('/abs/')) return await audiobookshelf(req, res, url);
    if (url.pathname.startsWith('/immich/')) return await immich(req, res, url);
    if (url.pathname.startsWith('/wizarr/')) return await wizarr(req, res, url);
    if (url.pathname.startsWith('/glances/')) return await glances(req, res, url);
    if (url.pathname.startsWith('/crowdsec/')) return crowdsec(req, res, url);
    if (url.pathname.startsWith('/synology/')) return await synology(req, res, url);
    if (url.pathname.startsWith('/dockhand/')) return await dockhand(req, res, url);
    if (url.pathname.startsWith('/komodo/')) return await komodo(req, res, url);
    if (url.pathname.startsWith('/coolify/')) return await coolify(req, res, url);
    if (url.pathname.startsWith('/arcane/')) return await arcane(req, res, url);
    if (url.pathname.startsWith('/beszel/')) return await beszel(req, res, url);
    if (url.pathname.startsWith('/technitium/')) return await technitium(req, res, url);
    if (url.pathname.startsWith('/controld/')) return await controld(req, res, url);
    if (url.pathname.startsWith('/nextdns/')) return await nextdns(req, res, url);
    if (url.pathname.startsWith('/gluetun/')) return await gluetun(req, res, url);
    if (url.pathname.startsWith('/qui/')) return await qui(req, res, url);
    if (url.pathname.startsWith('/tracearr/')) return await tracearr(req, res, url);
    if (url.pathname.startsWith('/dispatcharr/')) return await dispatcharr(req, res, url);
    if (url.pathname.startsWith('/seerr/')) return await seerrHandler(req, res, url);
    if (url.pathname === '/unraid/graphql' || url.pathname === '/unraid-old/graphql') return await unraidGraphQL(req, res, url);
    text(res, 404, 'unknown fixture');
  } catch (error) {
    text(res, 500, String(error));
  }
});

function frame(textPayload) {
  const payload = Buffer.from(textPayload);
  const header = payload.length < 126 ? Buffer.from([0x81, payload.length]) : Buffer.from([0x81, 126, payload.length >> 8, payload.length & 0xff]);
  return Buffer.concat([header, payload]);
}

function parseFrames(buffer, onText) {
  let offset = 0;
  while (buffer.length - offset >= 2) {
    let length = buffer[offset + 1] & 0x7f;
    let cursor = offset + 2;
    if (length === 126) { length = buffer.readUInt16BE(cursor); cursor += 2; }
    const mask = buffer.subarray(cursor, cursor + 4); cursor += 4;
    if (buffer.length < cursor + length) break;
    const data = Buffer.from(buffer.subarray(cursor, cursor + length));
    for (let i = 0; i < data.length; i++) data[i] ^= mask[i % 4];
    if ((buffer[offset] & 0x0f) === 0x1) onText(data.toString());
    offset = cursor + length;
  }
  return buffer.subarray(offset);
}

const truenasResults = {
  'system.info': { version: '25.10.1', hostname: 'vault', uptime_seconds: 100, model: 'Fixture CPU', cores: 4, physmem: 8, system_product: null, buildtime: { $date: 1 }, datetime: { $date: 1 } },
  'pool.query': [{ id: 1, name: 'tank', guid: 'g', status: 'ONLINE', path: '/mnt/tank', healthy: true, warning: false, status_code: 'OK', status_detail: null, size: 100, allocated: 25, free: 75, scan: null }],
  'disk.query': [{ identifier: '{serial}A', name: 'sda', serial: 'A', size: 100, model: 'Fixture Disk', type: 'HDD', pool: 'tank', rotationrate: 7200 }],
  'alert.list': [{ uuid: 'alert-1', level: 'WARNING', klass: 'Fixture', formatted: 'Fixture <i>alert</i>', text: '', dismissed: false, datetime: { $date: 1700000000000 } }],
  'pool.dataset.query': [{ id: 'tank/media', type: 'FILESYSTEM', name: 'media', pool: 'tank', encrypted: false, locked: false, used: { parsed: 10 }, available: { parsed: 90 }, mountpoint: '/mnt/tank/media' }],
  'core.get_jobs': [{ id: 1, method: 'pool.scrub.scrub', description: null, state: 'SUCCESS', progress: { percent: 100, description: null }, error: null, time_started: { $date: 1 }, time_finished: { $date: 2 } }],
  'pool.snapshottask.query': [
    { id: 1, dataset: 'tank/appdata', recursive: true, lifetime_value: 2, lifetime_unit: 'WEEK', enabled: true, exclude: [], naming_schema: 'auto-%Y-%m-%d_%H-%M', allow_empty: true, schedule: { minute: '0', hour: '*', dom: '*', month: '*', dow: '*', begin: '00:00', end: '23:59' }, vmware_sync: false, state: { state: 'FINISHED', datetime: { $date: 1759140000000 } } },
    { id: 2, dataset: 'tank/photos', recursive: false, lifetime_value: 1, lifetime_unit: 'MONTH', enabled: true, exclude: [], naming_schema: 'auto-%Y-%m-%d_%H-%M', allow_empty: true, schedule: { minute: '0', hour: '3', dom: '*', month: '*', dow: '*', begin: '00:00', end: '23:59' }, vmware_sync: false, state: { state: 'ERROR', datetime: { $date: 1759100000000 }, error: 'Dataset tank/photos is locked.' } },
    { id: 3, dataset: 'tank/new', recursive: false, lifetime_value: 1, lifetime_unit: 'DAY', enabled: false, exclude: [], naming_schema: 'auto-%Y-%m-%d', allow_empty: true, schedule: null, vmware_sync: false, state: 'PENDING' }],
};

const tls = createTLSServer({ cert: readFileSync(certPath), key: readFileSync(keyPath) }, (req, res) => req.url === '/rest' ? json(res, 200, ['secure']) : text(res, 404, ''));
tls.on('upgrade', (req, socket) => {
  if (req.url !== '/api/current') { socket.end('HTTP/1.1 404 Not Found\r\n\r\n'); return; }
  const accept = createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  let pending = Buffer.alloc(0);
  let authenticated = false;
  socket.on('data', (chunk) => {
    pending = parseFrames(Buffer.concat([pending, chunk]), (message) => {
      const request = JSON.parse(message);
      const reply = (body) => socket.write(frame(JSON.stringify({ jsonrpc: '2.0', id: request.id, ...body })));
      socket.write(frame(JSON.stringify({ jsonrpc: '2.0', method: 'collection_update', params: { msg: 'changed' } })));
      if (request.method === 'auth.login_with_api_key') { authenticated = request.params[0] === 'truenas-key'; return reply({ result: authenticated }); }
      if (!authenticated) return reply({ error: { code: -32001, message: 'Method call error', data: { errname: 'ENOTAUTHENTICATED', reason: 'Not authenticated' } } });
      if (request.method === 'alert.dismiss') { record(`truenas dismiss ${request.params[0]}`); return reply({ result: null }); }
      if (request.method === 'replication.query') return reply({ error: { code: -32001, message: 'Method call error', data: { errname: 'EACCES', reason: 'Not authorized' } } });
      if (request.method === 'pool.snapshottask.run') { record(`truenas snapshottask run ${request.params[0]}`); return reply({ result: null }); }
      if (request.method in truenasResults) return reply({ result: truenasResults[request.method] });
      reply({ error: { code: -32601, message: 'Method not found' } });
    });
  });
  socket.on('error', () => {});
});

http.listen(Number(httpPort), '127.0.0.1');
tls.listen(Number(httpsPort), '127.0.0.1', () => console.log('integration fixtures ready'));
