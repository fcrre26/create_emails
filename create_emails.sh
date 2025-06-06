#!/bin/bash

# 配置文件路径
config_file="$HOME/.email_config"

# 读取保存的邮箱后缀和SMTP服务器域名
if [ -f "$config_file" ]; then
    domain_suffix=$(grep "domain_suffix=" "$config_file" | cut -d '=' -f 2)
    smtp_host=$(grep "smtp_host=" "$config_file" | cut -d '=' -f 2)
    read -p "请输入邮箱后缀（例如yourdomain.com，默认为 $domain_suffix）：" input_domain_suffix
    if [ -n "$input_domain_suffix" ]; then
        domain_suffix="$input_domain_suffix"
    fi
    read -p "请输入SMTP服务器域名（需与证书一致，默认为 $smtp_host）：" input_smtp_host
    if [ -n "$input_smtp_host" ]; then
        smtp_host="$input_smtp_host"
    fi
else
    read -p "请输入邮箱后缀（例如yourdomain.com）：" domain_suffix
    read -p "请输入SMTP服务器域名（需与证书一致，如 mail.yourdomain.com）：" smtp_host
fi

# 保存邮箱后缀和SMTP服务器域名到配置文件
echo "domain_suffix=$domain_suffix" > "$config_file"
echo "smtp_host=$smtp_host" >> "$config_file"

# 密码输入，回车自动生成 (这个密码将用于所有生成的邮箱账户)
read -p "请输入要创建的邮箱账户的密码（直接回车自动生成）：" password
if [ -z "$password" ]; then
    password=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1)
    echo "生成的密码为：$password"
fi

# 创建输出文件
output_file="email_list.txt"
> "$output_file"  # 清空或创建文件

# 在容器内部创建邮箱账户
read -p "请输入要生成的邮箱数量：" count

# 录入收件邮箱地址 (用于发送包含列表的邮件)
read -p "请输入收件邮箱地址：" recipient_email
if [ -z "$recipient_email" ]; then
    echo "错误：请输入收件邮箱地址！"
    exit 1
fi

# === 修改部分：批量非交互式创建邮箱账号 ===

echo "开始批量创建 ${count} 个邮箱账号..."

# 容器名称，请根据你的实际情况确认，之前的日志显示是 1Panel-mysql-Kwkv，
# 但创建邮箱是maddy，根据原脚本是 1Panel-maddy-mail-iHBZ
maddy_container="1Panel-maddy-mail-iHBZ"

for ((i=1; i<=count; i++)); do
    username_length=$(shuf -i 6-8 -n 1)
    username=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w "$username_length" | head -n 1)
    full_email="${username}@${domain_suffix}"

    # 通过标准输入将密码传递给 maddy creds create 命令
    # -i 保持 STDIN 开放，-T 禁用 TTY 分配，/bin/sh -c 执行命令
    echo "$password" | docker exec -i "$maddy_container" /bin/sh -c "maddy creds create '${full_email}'"

    # 将生成的账号和使用的密码记录到输出文件
    echo "${full_email}----${password}----587" >> "$output_file"

    # 可以选择性地打印进度
    # echo "已创建 $i/$count: $full_email"

done

echo "邮箱账户创建完成，账号列表已保存到 $(pwd)/$output_file"

# === 修改部分结束 ===


# 固定发信账号和密码 (这部分是用于发送邮件的，保持不变)
sender_email="qcxfetp@19861019.xyz"
sender_password="q0BFHpXn"

# 配置msmtp，写入固定账号和密码 (这部分是用于发送邮件的，保持不变)
msmtp_config="$HOME/.msmtprc"
cat > "$msmtp_config" << EOF
account default
host $smtp_host
port 587
auth on
user $sender_email
password $sender_password
from $sender_email
tls on
tls_starttls on
logfile ~/.msmtp.log
EOF

chmod 600 "$msmtp_config"

# 发送带附件的邮件（MIME格式，纯msmtp）(这部分是用于发送邮件的，保持不变)
boundary="ZZ_$(date +%s)_ZZ"
{
    echo "To: $recipient_email"
    echo "From: $sender_email"
    echo "Subject: 邮箱列表"
    echo "MIME-Version: 1.0"
    echo "Content-Type: multipart/mixed; boundary=\"$boundary\""
    echo
    echo "--$boundary"
    echo "Content-Type: text/plain; charset=utf-8"
    echo
    echo "请查收附件中的邮箱列表。"
    echo
    echo "--$boundary"
    echo "Content-Type: text/plain; name=\"email_list.txt\""
    echo "Content-Transfer-Encoding: base64"
    echo "Content-Disposition: attachment; filename=\"email_list.txt\""
    echo
    base64 "$output_file"
    echo "--$boundary--"
} | msmtp -t

echo "邮件已发送到 $recipient_email（附件方式）"
