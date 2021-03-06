#!/usr/bin/env bash
# VPS一键安装V2ray脚本(websocket + nginx + tls)(Ubuntu18.04)
#0. 前言：必须先在dns服务商将二级域名指向新开的服务器，再在服务器上执行本脚本
#1. 更新系统
#2. 安装Nginx
#3. 申请证书：acme.sh
#4. 安装V2ray, 配置生成：https://www.veekxt.com/utils/v2ray_gen
#5. 安装完成后，将服务器上的/etc/v2ray/config.json.client 文件复制到本地的/etc/v2ray 文件夹下，并重命名为config.json后，重启本地v2ray即可
#6. PS：实测使用websocket+nginx+tls模拟 正常访问网站已经足够绕过GFW识别，没有持续大流量访问的情况下，没有必要用Cloudfare的CDN
#Date: 2019-06-16
#2019-06-20: 增加一个404页面作为二级域名的主页
#2019-06-27: 随机生成websocket的链接，随机生成字符串作为v2ray的链接，不再固定为ws


#说明
showUsage() {
cat 1>&2 <<EOF
*-----------------------------------------------------------------------
one key to install v2ray, nginx and apply tls cert script. usage:
available args:
[-d|--domain]: your vps domain name, pointing to current vps
*-----------------------------------------------------------------------
v2ray 一键安装脚本，自动安装v2ray, nginx, 自动申请证书，自动更新证书，自动生成websocket+nginx+tls模式的服务端和客户端配置
使用方式：分别执行以下两行命令
[1] cd /usr/local && git clone https://github.com/abcfyk/impatriot.git && cd impatriot/v2ray
[2] bash ws_nginx_tls.sh -d 你的域名
注意： 使用本脚本前必须先将域名指向这台服务器
*-----------------------------------------------------------------------
EOF
}

printr() {
    echo; echo "## $1"; echo;
}

# 生成随机数字
function rand(){
    min=$1
    max=$(($2-$min+1))
    num=$(cat /proc/sys/kernel/random/uuid | cksum | awk -F ' ' '{print $1}')
    echo $(($num%$max+$min))
}

#生成随机长度的字符串,默认为5到8位
function randStr() {
    len=`rand 5 8`;
    echo $(date +%s%N | md5sum | head -c ${len});
}


#获取参数
PROXY_DOMAIN="";
GET_ARGS=`getopt -o d: -al domain: -- "$@"`
eval set -- "$GET_ARGS"

#开始处理
while [ -n "$1" ]
do
    case "$1" in
        -d|--domain) PROXY_DOMAIN=$2; shift 2;;
        --) break ;;
        *) showUsage; break ;;
    esac
done

#判断参数有效性:
if [[ -z "${PROXY_DOMAIN}" ]]; then
    showUsage;
    exit 1;
fi

CURRENT_IP=$(ifconfig -a | grep inet | grep -v "127.0.0.1\|inet6\|0.0.0.0" | awk '{print $2}' | tr -d "addr:");
DOMAIN_IP=$(nslookup ${PROXY_DOMAIN} 8.8.8.8 | grep -v "8.8.8.8\|127.0.0.53" | grep "Address:"  | awk '{print $2}');

if [[ "${CURRENT_IP}" != "${DOMAIN_IP}" ]]; then
    printr "[ERROR]:  the domain: ${PROXY_DOMAIN} didn't point to current server.";
    exit 1;
fi

#请勿修改以下配置-------------------------------------------
#配置二级域名来转发v2ray流量，不要用一级域名
PROXY_DOMAIN_CERT_FILE="/etc/nginx/ssl/${PROXY_DOMAIN}.fullchain.cer"
PROXY_DOMAIN_KEY_FILE="/etc/nginx/ssl/${PROXY_DOMAIN}.key"

#UUID
UUID=`cat /proc/sys/kernel/random/uuid`;

#使用随机字符串作为v2ray流量入口
V2RAY_PATH=`randStr`;

#0. 验证：
#0.1 系统
if [[ 'ubuntu' != "$(cat /etc/os-release | grep -w ID | awk -F '=' '{print $2}')" ]]; then
    echo "System Not UBuntu, exit";
    exit 1;
fi

#1. 基础配置 ：
apt update
apt -y upgrade

#1.0  机器名，时区
#echo ${HOST_NAME} > /etc/hostname && hostname ${HOST_NAME}
timedatectl set-timezone Asia/Shanghai

## 1.1 配置命令alias:
cat >> ~/.bashrc << EOF
alias egrep='egrep --color=auto'
alias fgrep='fgrep --color=auto'
alias grep='grep --color=auto'
alias l='ls -CF'
alias la='ls -A'
alias ll='ls -alF'
alias ls='ls --color=auto'
EOF
source ~/.bashrc

#1.2 配置vim(Debian):
# 备份
cp /usr/share/vim/vim80/defaults.vim /usr/share/vim/vim80/defaults.vim.bak
#1.2.1 取消可视化模式(删除带有set mouse=a)
lines=`grep -n 'set mouse=a' /usr/share/vim/vim80/defaults.vim | tail -1 | awk -F ":" '{print $1}'`;
if [ ${lines} -gt 0 ]; then
    startM=`expr ${lines} - 1`;
    endN=`expr ${lines} + 1`;
    sed -i ${startM},${endN}d /usr/share/vim/vim80/defaults.vim
fi

#1.3 开启bbr(Debian9 4.9内核以上已经集成bbr，打开配置即可)
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p
sysctl net.ipv4.tcp_available_congestion_control

#4. 安装Nginx
#4.1 安装
apt install -y nginx

#4.2 配置nginx.conf, 默认主页为404页面
mkdir -p /export/www/${PROXY_DOMAIN}
if [ ! -f "../404/404.html" ]; then
echo "hello" > /export/www/${PROXY_DOMAIN}/index.html
else
cp ../404/404.html /export/www/${PROXY_DOMAIN}/index.html
fi
mkdir -p /var/log/nginx

mv /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
cat >  /etc/nginx/nginx.conf << EOF
user  www-data;
worker_processes  auto;

error_log  /var/log/nginx/error.log warn;
pid        /var/run/nginx.pid;

worker_rlimit_nofile 65535;

events {
    use epoll;
    worker_connections  8192;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    charset utf-8;
    client_header_buffer_size 32k; #上传文件大小限制
    large_client_header_buffers 4 64k; #设定请求缓
    client_max_body_size 8m; #设定请求缓存大小

    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '"\$http_user_agent" "\$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;

    keepalive_timeout  60;

    #gzip模块设置
    gzip               on;
    gzip_vary          on;
    gzip_comp_level    6;
    gzip_buffers       16 8k;
    gzip_min_length    1000;
    gzip_proxied       any;
    gzip_disable       "msie6";
    gzip_http_version  1.0;
    gzip_types         text/plain text/css application/json application/x-javascript text/xml application/xml application/xml+rss text/javascript application/javascript;

    include /etc/nginx/conf.d/*.conf;

    #站点配置
    server {
        listen  80;
        server_name ${PROXY_DOMAIN};
        root    /export/www/${PROXY_DOMAIN};
        index   index.html index.htm index.php;
    }
}
EOF

#5. 重启
service nginx restart

#6. 安装acme.sh 自动更新tls证书
curl  https://get.acme.sh | sh
source ~/.bashrc

#6.1 创建证书存放文件夹
mkdir -p /etc/nginx/ssl

#6.2 申请证书
/root/.acme.sh/acme.sh  --issue -d ${PROXY_DOMAIN} --webroot /export/www/${PROXY_DOMAIN}

#6.3 安装证书
/root/.acme.sh/acme.sh --installcert -d ${PROXY_DOMAIN} \
--key-file ${PROXY_DOMAIN_KEY_FILE} \
--fullchain-file ${PROXY_DOMAIN_CERT_FILE} \
--reloadcmd "service nginx force-reload"

#6.4 自动更新证书
/root/.acme.sh/acme.sh  --upgrade  --auto-upgrade

#7. 安装V2ray veekxt.com
curl -L -s https://install.direct/go.sh | bash;
mv /etc/v2ray/config.json /etc/v2ray/config.json.bak
cat > /etc/v2ray/config.json << EOF
{
  "log": {
    "access": "/var/log/v2ray/access.log",
    "error": "/var/log/v2ray/error.log",
    "loglevel": "warning"
  },
  "dns": {},
  "stats": {},
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/${V2RAY_PATH}"
        },
        "security": "none"
      },
      "tag": "in-0",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "alterId": 32
          }
        ]
      },
      "protocol": "vmess",
      "port": 44222
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "settings": {},
      "protocol": "freedom"
    },
    {
      "tag": "blocked",
      "settings": {},
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "blocked"
      }
    ],
    "domainStrategy": "AsIs"
  },
  "policy": {},
  "reverse": {},
  "transport": {}
}
EOF


#6.2 更新Nginx的tls配置
cat >  /etc/nginx/nginx.conf << EOF
user  www-data;
worker_processes  auto;

error_log  /var/log/nginx/error.log warn;
pid        /var/run/nginx.pid;

worker_rlimit_nofile 65535;

events {
    use epoll;
    worker_connections  8192;
    multi_accept on;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    charset utf-8;
    access_log  off;

    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;

    keepalive_timeout  60;

    #gzip模块设置
    gzip               on;
    gzip_vary          on;
    gzip_comp_level    6;
    gzip_buffers       16 8k;
    gzip_min_length    1000;
    gzip_proxied       any;
    gzip_disable       "msie6";
    gzip_http_version  1.0;
    gzip_types         text/plain text/css application/json application/x-javascript text/xml application/xml application/xml+rss text/javascript application/javascript;

    include /etc/nginx/conf.d/*.conf;

    #站点配置
    server {
        listen  80;
        server_name ${PROXY_DOMAIN};
        rewrite ^(.*)$  https://\$host\$1 permanent;
    }
    server {
        listen 443 ssl;

        ssl on;
        ssl_certificate       ${PROXY_DOMAIN_CERT_FILE};
        ssl_certificate_key   ${PROXY_DOMAIN_KEY_FILE};
        ssl_protocols         TLSv1.1 TLSv1.2;
        ssl_ciphers           EECDH+CHACHA20:EECDH+AES128:RSA+AES128:EECDH+AES256:RSA+AES256:EECDH+3DES:RSA+3DES:!MD5;
        ssl_prefer_server_ciphers on; #优化SSL加密
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 60m;

        root /export/www/${PROXY_DOMAIN};
        index index.html index.htm index.nginx-debian.html;
        server_name _;
        location / {
            try_files \$uri \$uri/ =404;
        }

        location /${V2RAY_PATH} {
            proxy_redirect off;
            proxy_pass http://127.0.0.1:44222;

            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$http_host;
            proxy_read_timeout 300s;
        }
    }
}
EOF


#6.3 客户端配置(复制到本地)
cat > /etc/v2ray/config.json.client << EOF
{
  "log":{},
  "dns":{},
  "stats":{},
  "inbounds":[
    {
      "tag":"in-0",
      "settings":{
        "udp":true,
        "auth":"noauth"
      },
      "port":"1080",
      "protocol":"socks"
    },
    {
      "tag":"in-1",
      "settings":{},
      "port":"1081",
      "protocol":"http"
    }
  ],
  "outbounds":[
    {
      "tag":"out-0",
      "settings":{
        "vnext":[
          {
            "users":[
              {
                "id":"${UUID}",
                "alterId":32
              }
            ],
            "address":"${PROXY_DOMAIN}",
            "port":443
          }
        ]
      },
      "streamSettings":{
        "network":"ws",
        "wsSettings":{
          "path":"/${V2RAY_PATH}"
        },
        "tlsSettings":{
          "serverName":"${PROXY_DOMAIN}"
        },
        "security":"tls"
      },
      "protocol":"vmess"
    },
    {
      "tag":"direct",
      "settings":{},
      "protocol":"freedom"
    },
    {
      "tag":"blocked",
      "settings":{},
      "protocol":"blackhole"
    }
  ],
  "routing":{
    "rules":[
      {
        "type":"field",
        "ip":[
          "geoip:private"
        ],
        "outboundTag":"direct"
      }
    ],
    "domainStrategy":"IPOnDemand"
  },
  "policy":{},
  "reverse":{},
  "transport":{}
}
EOF

#6.4 重启nginx and v2ray
service nginx restart
systemctl restart v2ray

#7. 优化
cat > /etc/sysctl.d/default.conf << EOF
# 最大打开文件
fs.file-max = 51200
# 最大读取缓冲区
net.core.rmem_max = 67108864
# 最大写入缓冲区
net.core.wmem_max = 67108864
# 默认读取缓冲区
net.core.rmem_default = 65536
# 默认写入缓冲区
net.core.wmem_default = 65536
# 最大处理器输入队列
net.core.netdev_max_backlog = 4096
# 最大积压量
net.core.somaxconn = 4096

# 抵御 SYN 洪水攻击
net.ipv4.tcp_syncookies = 1
# 安全时重用 timewait 套接字
net.ipv4.tcp_tw_reuse = 1
# 关闭快速 timewait 套接字回收
net.ipv4.tcp_tw_recycle = 0
# FIN 超时时间
net.ipv4.tcp_fin_timeout = 30
# keepalive 间隔时间
net.ipv4.tcp_keepalive_time = 1200
# 出站端口范围
net.ipv4.ip_local_port_range = 10000 65000
# 最大 SYN 积压
net.ipv4.tcp_max_syn_backlog = 4096
# 由系统同时持有的最大 timewait 套接字
net.ipv4.tcp_max_tw_buckets = 5000
# 开启 TCP Fast Open
net.ipv4.tcp_fastopen = 3
# TCP 接收缓冲区
net.ipv4.tcp_rmem = 4096 87380 67108864
# TCP 写入缓冲区
net.ipv4.tcp_wmem = 4096 65536 67108864
# 开启 MTU 探测
net.ipv4.tcp_mtu_probing = 1

# 开启忽略 ICMP 请求
#net.ipv4.icmp_echo_ignore_all = 1

# 适用于高延迟网络
#net.ipv4.tcp_congestion_control = hybla

# 对于低延迟网络，用 cubic 代替
#net.ipv4.tcp_congestion_control = cubic

# BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
sysctl --system

#7.2 增加文件描述符限制, <所有用户> <软限制和硬限制> <文件描述符> <整型数值>
mkdir -p /etc/security/limits.d
echo "* - nofile 51200" > /etc/security/limits.d/default.conf;

echo "conguatulations. install finished, please copy the config file to your local machine.";