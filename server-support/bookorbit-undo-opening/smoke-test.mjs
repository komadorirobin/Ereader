import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';

const [checkout] = process.argv.slice(2);
if (!checkout) throw new Error('Usage: node smoke-test.mjs BOOKORBIT_CHECKOUT');
const database = new URL(process.env.OPENING_TEST_DATABASE_URL || '');
const base = new URL(process.env.OPENING_TEST_API_URL || '');
if (database.hostname !== '127.0.0.1' || database.pathname !== '/bookorbit_undo_test' || base.hostname !== '127.0.0.1') {
    throw new Error('Use only an isolated local bookorbit_undo_test database and API');
}
const require = createRequire(resolve(checkout, 'server/package.json'));
const { Pool } = require('pg');
const pool = new Pool({ connectionString: database.href, connectionTimeoutMillis: 10000 });
const fixture = randomUUID();
const key = createHash('md5').update(fixture).digest('hex');
const userIds = [];
let libraryId;
let checks = 0;

async function row(sql, values) {
    return (await pool.query(sql, values)).rows[0];
}

async function post(path, body, expected, username) {
    const response = await fetch(new URL(`/api/v1/koreader/plugin/openings${path}`, base), {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            ...(username ? { 'x-auth-user': username, 'x-auth-key': key } : {}),
        },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(10000),
    });
    const data = await response.json();
    assert.equal(response.status, expected, `${path || 'start'}: ${JSON.stringify(data)}`);
    checks++;
    return data;
}

try {
    // Unique fixtures have no external tokens. Never reuse a real user's credentials.
    for (const suffix of ['owner', 'other']) {
        const user = await row(
            'INSERT INTO users (username, name, password_hash) VALUES ($1, $2, $3) RETURNING id',
            [`undo-smoke-${fixture}-${suffix}`, 'Isolated opening smoke test', 'not-a-real-password'],
        );
        userIds.push(user.id);
        await pool.query('INSERT INTO user_permissions (user_id, permission_name) VALUES ($1, $2)', [user.id, 'koreader_sync']);
        await pool.query(
            'INSERT INTO koreader_users (user_id, username, password_hash, password_md5) VALUES ($1, $2, $3, $4)',
            [user.id, `undo-smoke-${fixture}-${suffix}`, 'not-a-real-password', key],
        );
    }
    const owner = `undo-smoke-${fixture}-owner`;
    const other = `undo-smoke-${fixture}-other`;
    const library = await row('INSERT INTO libraries (name) VALUES ($1) RETURNING id', [`Undo smoke ${fixture}`]);
    libraryId = library.id;
    await pool.query('INSERT INTO user_library_access (user_id, library_id) VALUES ($1, $2)', [userIds[0], libraryId]);
    const folder = await row('INSERT INTO library_folders (library_id, path) VALUES ($1, $2) RETURNING id', [libraryId, `/undo-smoke/${fixture}`]);
    const book = await row(
        'INSERT INTO books (library_id, library_folder_id, folder_path) VALUES ($1, $2, $3) RETURNING id',
        [libraryId, folder.id, `/undo-smoke/${fixture}/book`],
    );
    const document = createHash('md5').update(`book-${fixture}`).digest('hex');
    await pool.query(
        'INSERT INTO book_files (book_id, library_folder_id, absolute_path, ino, format, file_hash) VALUES ($1, $2, $3, 1, $4, $5)',
        [book.id, folder.id, `/undo-smoke/${fixture}/book.epub`, 'epub', document],
    );
    await pool.query('INSERT INTO user_book_status (user_id, book_id, status) VALUES ($1, $2, $3)', [userIds[0], book.id, 'want_to_read']);
    const opening = { id: randomUUID(), document, deviceId: 'undo-smoke-reader' };
    for (const path of ['', '/commit', '/undo']) await post(path, opening, 401);
    await post('', { ...opening, id: 'invalid' }, 400, owner);
    await post('', opening, 404, other);
    const active = await post('', opening, 201, owner);
    assert.deepEqual(active, { id: opening.id, phase: 'active', hardcoverPending: false });
    assert.deepEqual(await post('', opening, 201, owner), active);
    await post('/undo', opening, 404, other);
    await post('/undo', { ...opening, deviceId: 'different-device' }, 404, owner);
    const undone = await post('/undo', opening, 201, owner);
    assert.deepEqual(undone, { id: opening.id, phase: 'undone', hardcoverPending: false });
    assert.deepEqual(await post('/undo', opening, 201, owner), undone);
    await post('/commit', opening, 409, owner);
    assert.equal((await row('SELECT status FROM user_book_status WHERE user_id = $1 AND book_id = $2', [userIds[0], book.id])).status, 'want_to_read');
    assert.deepEqual(await row(
        'SELECT count(*)::int AS total, count(*) FILTER (WHERE deleted_at IS NOT NULL)::int AS deleted FROM reading_attempts WHERE user_id = $1 AND book_id = $2',
        [userIds[0], book.id],
    ), { total: 1, deleted: 1 });

    const reopened = { ...opening, id: randomUUID() };
    await post('', reopened, 201, owner);
    const committed = await post('/commit', reopened, 201, owner);
    assert.deepEqual(committed, { id: reopened.id, phase: 'committed', hardcoverPending: false });
    assert.deepEqual(await post('/commit', reopened, 201, owner), committed);
    await post('/undo', reopened, 409, owner);
    assert.equal((await row('SELECT status FROM user_book_status WHERE user_id = $1 AND book_id = $2', [userIds[0], book.id])).status, 'reading');
    console.log(`Passed ${checks} HTTP checks, status restoration and owned-attempt tombstone checks.`);
} finally {
    try {
        if (libraryId) await pool.query('DELETE FROM libraries WHERE id = $1', [libraryId]);
        for (const userId of userIds) await pool.query('DELETE FROM users WHERE id = $1', [userId]);
    } finally {
        await pool.end();
    }
}
