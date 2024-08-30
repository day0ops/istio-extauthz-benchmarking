import http from 'k6/http';
import { check } from 'k6';

export const options = {
    vus: 1000,
    duration: '5m',
    thresholds: {
        http_req_failed: [{ threshold: "rate<0.001", abortOnFail: true }], // http errors should be less than 0.01% and if not abort
        http_req_duration: ['p(99)<1000'], // 99% of requests should be below 1s
    },
};

export default () => {
    const options = {
        headers: {
          Authorization: `Bearer ${__ENV.AUTH_TOKEN}`,
        },
    };
    const res = http.get(`http:/${__ENV.EXTERNAL_GW_ADDR}//status/200`, options);
    const st = check(res, { 
        '200': (r) => r.status === 200,
    });
    checkResult(res, st)
};

function checkResult(res, status) {
    if (!status) {
      console.error(res)
    }
}