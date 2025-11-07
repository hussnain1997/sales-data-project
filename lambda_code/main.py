import json
import pymysql
import boto3
import os
from datetime import date

def lambda_handler(event, context):
    # Get secrets
    secrets_client = boto3.client('secretsmanager')
    secret = secrets_client.get_secret_value(SecretId='sales-rds-creds')
    creds = json.loads(secret['SecretString'])
    
    # Connect to RDS
    conn = pymysql.connect(
        host=creds['host'],
        user=creds['username'],
        password=creds['password'],
        database=creds['dbname']
    )
    cursor = conn.cursor()
    
    mode = event.get('mode', 'daily')
    
    if mode == 'init':
        # Create table and insert sample data
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS sales (
                id INT AUTO_INCREMENT PRIMARY KEY,
                sale_date DATE,
                amount DECIMAL(10,2)
            )
        """)
        sample_data = [
            (date.today(), 100.50),
            (date.today(), 200.75),
        ]
        cursor.executemany("INSERT INTO sales (sale_date, amount) VALUES (%s, %s)", sample_data)
        conn.commit()
        return {'status': 'Table created and data inserted'}
    
    elif mode == 'daily':
        # Process: Get total sales for today
        today = date.today()
        cursor.execute("SELECT SUM(amount) FROM sales WHERE sale_date = %s", (today,))
        total = cursor.fetchone()[0] or 0.0
        
        # SNS Publish (simple message)
        sns_client = boto3.client('sns')
        sns_client.publish(
            TopicArn=os.environ.get('SNS_TOPIC_ARN', 'arn:aws:sns:us-east-1:123456789012:sales-notifications'),  # Replace or set env var
            Message=f"Daily Sales Total: ${total}"
        )
        
        # SES (Bonus: HTML email with table)
        ses_client = boto3.client('ses')
        cursor.execute("SELECT * FROM sales WHERE sale_date = %s", (today,))
        rows = cursor.fetchall()
        
        html_table = "<table><tr><th>ID</th><th>Date</th><th>Amount</th></tr>"
        for row in rows:
            html_table += f"<tr><td>{row[0]}</td><td>{row[1]}</td><td>{row[2]}</td></tr>"
        html_table += "</table>"
        
        ses_client.send_email(
            Source=var.sns_email,  # Verified sender
            Destination={'ToAddresses': [var.sns_email]},
            Message={
                'Subject': {'Data': 'Daily Sales Report'},
                'Body': {
                    'Html': {'Data': f"<h1>Daily Sales Total: ${total}</h1>{html_table}"}
                }
            }
        )
        
        conn.close()
        return {'status': 'Processed and notified'}
