#!/usr/bin/env node
import { main } from '../lib/native-app.mjs';
main(process.argv.slice(2)).catch(error => { console.error(error.message); process.exitCode = 1; });
