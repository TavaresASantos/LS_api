const request = require('supertest');
const app = require('../src/index');

describe('API básica', () => {
  test('GET /status retorna status OK', async () => {
    const res = await request(app).get('/status');
    expect(res.statusCode).toBe(200);
    expect(res.body).toHaveProperty('status', 'OK');
    expect(res.body).toHaveProperty('environment');
  });

  test('GET /checkEnvironment retorna mensagem ok', async () => {
    const res = await request(app).get('/checkEnvironment');
    expect(res.statusCode).toBe(200);
    expect(res.body).toHaveProperty('message', 'ok');
  });
});
