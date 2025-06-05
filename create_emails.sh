#!/bin/bash

# 配置文件路径
config_file="$HOME/.email_config"

# 读取保存的邮箱后缀
if [ -f "$config_file" ]; then
    domain_suffix=$(grep "domain_suffix=" "$config_file" | cut -d '=' -f 2)
    read -p "请输入邮箱后缀（例如yourdomain.com，默认为 $domain_suffix）：" input_domain_suffix
    if [ -n "$input_domain_suffix" ]; then
        domain_suffix="$input_domain_suffix"
    fi
else
    read -p "请输入邮箱后缀（例如yourdomain.com）：" domain_suffix
fi

# 保存邮箱后缀到配置文件
echo "domain_suffix=$domain_suffix" > "$config_file"

# 读取密码选择
read -p "是否自动生成密码？（输入1自动生成，输入其他手动输入）：" password_choice

if [ "$password_choice" = "1" ]; then
    # 自动生成8位随机密码
    password=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1)
    echo "生成的密码为：$password"
else
    # 手动输入密码
    read -p "请输入密码：" password
fi

# 自动生成发件邮箱（使用第一个生成的邮箱作为发件邮箱）
username_length=$(shuf -i 6-8 -n 1)
username=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w "$username_length" | head -n 1)
sender_email="${username}@${domain_suffix}"

# 创建输出文件
output_file="email_list.txt"
> "$output_file"  # 清空或创建文件

# 在容器内部创建邮箱账户
read -p "请输入要生成的邮箱数量：" count
for ((i=1; i<=count; i++)); do
    # 生成随机用户名长度（6到8位）
    username_length=$(shuf -i 6-8 -n 1)
    
    # 生成随机用户名，包含小写字母和数字
    username=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w "$username_length" | head -n 1)
    
    full_email="${username}@${domain_suffix}"
    
    # 创建邮箱账户，使用 expect 处理交互式密码输入
    expect -c "
        spawn docker exec -it 1Panel-maddy-mail-iHBZ /bin/sh -c \"maddy creds create '${full_email}'\"
        expect \"Enter password for new user:\"
        send \"${password}\r\"
        expect eof
    "
    
    # 将邮箱信息写入文件，格式为“邮箱----密码”
    echo "${full_email}----${password}" >> "$output_file"
done

echo "邮箱账户创建完成，邮箱列表已保存到 $(pwd)/$output_file"

# 配置msmtp
msmtp_config="$HOME/.msmtprc"
cat > "$msmtp_config" << EOF
account default
host localhost
port 587
auth on
user $sender_email
password $password
from $sender_email
tls on
tls_starttls on
logfile ~/.msmtp.log
EOF

chmod 600 "$msmtp_config"

# 输入收件邮箱地址
read -p "请输入收件邮箱地址：" recipient_email

# 发送邮件
echo "请查收附件中的邮箱列表。" | msmtp -t "$recipient_email" -s "邮箱列表" --attach "$output_file"
