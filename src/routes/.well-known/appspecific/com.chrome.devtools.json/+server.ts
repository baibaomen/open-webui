import { json } from '@sveltejs/kit';

export async function GET() {
	// 返回空的 JSON 对象给 Chrome DevTools
	return json({});
} 