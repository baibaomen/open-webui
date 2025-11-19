### 项目启动

#### 后端
1. 激活虚拟环境
source venv/Scripts/activate  # Git Bash
2. cd backend
3. python -m uvicorn open_webui.main:app --host 0.0.0.0 --port 8080
#### 前端
npm run dev

#### 前端发布
1. npm run build
2. 打包build文件夹
3. 复制到服务器并解压 
cd /open-webui/frontend
unzip -o build.zip  
5. 重启docker compose
docker compose restart