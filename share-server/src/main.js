import pg from 'pg';
import { Store } from './store.js';
import { createServer } from './server.js';
const pool=new pg.Pool({connectionString:process.env.DATABASE_URL,max:10,connectionTimeoutMillis:10000,statement_timeout:30000});
const store=new Store(pool);await store.init();
const app=await createServer({store,origin:process.env.PUBLIC_ORIGIN,enrollmentCode:process.env.ENROLLMENT_CODE,allowHTTP:process.env.DEV_ALLOW_HTTP==='1'});
const port=Number(process.env.PORT||8787);
app.server.listen(port,process.env.BIND_ADDRESS||'127.0.0.1',()=>console.log(`FinderFlow share relay listening on port ${port}`));
for(const signal of ['SIGTERM','SIGINT'])process.on(signal,async()=>{await app.close();await pool.end();process.exit(0);});
